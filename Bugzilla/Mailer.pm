# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Mailer;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);
our @EXPORT = qw(MessageToMTA build_thread_marker); ## no critic (Modules::ProhibitAutomaticExportation)

use Bugzilla::Logging;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Hook;
use Bugzilla::Util;

use Date::Format qw(time2str);

use Email::Address::XS;
use Email::MIME;
use Encode qw(encode);
use Encode::MIME::Header;
use List::MoreUtils qw(none);
use Try::Tiny;

use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Bugzilla::Sender::Transport::Sendmail;
use Sys::Hostname;
use Bugzilla::Version qw(vers_cmp);

sub MessageToMTA {
  my ($msg, $send_now) = (@_);
  my $method = Bugzilla->get_param_with_override('mail_delivery_method');
  return if $method eq 'None';

  if (Bugzilla->get_param_with_override('use_mailer_queue') and !$send_now) {
    Bugzilla->job_queue->insert('send_mail', {msg => $msg});
    return;
  }

  my $dbh = Bugzilla->dbh;

  my $email = ref $msg ? $msg : Email::MIME->new($msg);
  $email->encode_check_set(Encode::FB_DEFAULT);

  # Ensure that we are not sending emails too quickly to recipients.
  if (Bugzilla->get_param_with_override('use_mailer_queue')
    && (EMAIL_LIMIT_PER_MINUTE || EMAIL_LIMIT_PER_HOUR))
  {
    $dbh->do("DELETE FROM email_rates WHERE message_ts < "
        . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'HOUR'));

    my $recipient = $email->header('To');

    if (EMAIL_LIMIT_PER_MINUTE) {
      my $minute_rate = $dbh->selectrow_array(
        "SELECT COUNT(*)
                   FROM email_rates
                  WHERE recipient = ?  AND message_ts >= "
          . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'MINUTE'), undef,
        $recipient
      );
      if ($minute_rate >= EMAIL_LIMIT_PER_MINUTE) {
        die EMAIL_LIMIT_EXCEPTION;
      }
    }
    if (EMAIL_LIMIT_PER_HOUR) {
      my $hour_rate = $dbh->selectrow_array(
        "SELECT COUNT(*)
                   FROM email_rates
                  WHERE recipient = ?  AND message_ts >= "
          . $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', '1', 'HOUR'), undef,
        $recipient
      );
      if ($hour_rate >= EMAIL_LIMIT_PER_HOUR) {
        die EMAIL_LIMIT_EXCEPTION;
      }
    }
  }

  # We add this header to uniquely identify all email that we
  # send as coming from this Bugzilla installation.
  #
  $email->header_set('X-Bugzilla-URL', Bugzilla->localconfig->urlbase);

  # We add this header to mark the mail as "auto-generated" and
  # thus to hopefully avoid auto replies.
  $email->header_set('Auto-Submitted', 'auto-generated');

  # MIME-Version must be set otherwise some mailsystems ignore the charset
  $email->header_set('MIME-Version', '1.0')
    if !$email->header('MIME-Version');

  # Encode the headers correctly in quoted-printable
  foreach my $header ($email->header_names) {
    $header = lc $header;
    my @values = $email->header($header);
    my @new_values;
    foreach my $value (@values) {
      if (Bugzilla->params->{'utf8'} && !utf8::is_utf8($value)) {
        utf8::decode($value);
      }
      push @new_values, $value;
    }

    # header_str_set will handle encoding of values if needed.
    $email->header_str_set($header, @new_values);
  }

  my $from = $email->header('From');

  my $hostname;
  my $transport;
  if ($method eq "Sendmail") {
    if (ON_WINDOWS) {
      $transport = Bugzilla::Sender::Transport::Sendmail->new({ sendmail => SENDMAIL_EXE });
    }
    else {
      $transport = Bugzilla::Sender::Transport::Sendmail->new();
    }
  }
  else {
    # Sendmail will automatically append our hostname to the From
    # address, but other mailers won't.
    my $urlbase = Bugzilla->localconfig->urlbase;
    $urlbase =~ m|//([^:/]+)[:/]?|;
    $hostname = $1;
    $from .= "\@$hostname" if $from !~ /@/;
    $email->header_set('From', $from);

    # Sendmail adds a Date: header also, but others may not.
    if (!defined $email->header('Date')) {
      $email->header_set('Date', time2str("%a, %d %b %Y %T %z", time()));
    }
  }

  # For tracking/diagnostic purposes, add our hostname
  my $generated_by = $email->header('X-Generated-By') || '';
  if ($generated_by =~ tr/\/// < 3) {
    $email->header_set(
      'X-Generated-By' => $generated_by . '/' . hostname() . "($$)");
  }

  if ($method eq "SMTP") {
    my ($host, $port) = split(/:/, Bugzilla->params->{'smtpserver'}, 2);
    $transport = Email::Sender::Transport::SMTP->new({
      host => $host,
      defined($port) ? (port => $port) : (),
      sasl_username => Bugzilla->params->{'smtp_username'},
      sasl_password => Bugzilla->params->{'smtp_password'},
      helo          => $hostname,
      ssl           => Bugzilla->params->{'smtp_ssl'},
      debug         => Bugzilla->params->{'smtp_debug'}
    });
  }

  Bugzilla::Hook::process('mailer_before_send', {email => $email});

  try {
    my $to         = $email->header('to') or die qq{Unable to find "To:" address\n};
    my @recipients = Email::Address::XS->parse($to);
    die qq{Unable to parse "To:" address - $to\n} unless @recipients;
    die qq{Did not expect more than one "To:" address in $to\n} if @recipients > 1;
    die qq{Invalid address in "To:" address - $to\n} if !$recipients[0]->is_valid;
    my $recipient = $recipients[0];
    my $badhosts  = Bugzilla::Bloomfilter->lookup("badhosts");
    if ($badhosts && $badhosts->test($recipient->host)) {
      WARN("Attempted to send email to address in badhosts: $to");
      $email->header_set(to => '');
    }
    elsif ($recipient->host =~ /\.(?:bugs|tld)$/) {
      WARN("Attempted to send email to fake address: $to");
      $email->header_set(to => '');
    }
  }
  catch {
    ERROR($_);
  };

  # Allow for extensions to to drop the bugmail by clearing the 'to' header
  return if $email->header('to') eq '';

  $email->walk_parts(sub {
    my ($part) = @_;
    return if $part->parts > 1;    # Top-level
    my $content_type = $part->content_type || '';
    $content_type =~ /charset=['"](.+)['"]/;

    # If no charset is defined or is the default us-ascii,
    # then we encode the email to UTF-8 if Bugzilla has UTF-8 enabled.
    # XXX - This is a hack to workaround bug 723944.
    if (!$1 || $1 eq 'us-ascii') {
      my $body = $part->body;
      if (Bugzilla->params->{'utf8'}) {
        $part->charset_set('UTF-8');

        # encoding_set works only with bytes, not with UTF-8 strings.
        my $raw = $part->body_raw;
        if (utf8::is_utf8($raw)) {
          utf8::encode($raw);
          $part->body_set($raw);
        }
      }
      $part->encoding_set('quoted-printable') if !is_7bit_clean($body);
    }
  });

  if ($method eq "Test") {
    my $filename = bz_locations()->{'datadir'} . '/mailer.testfile';
    open TESTFILE, '>>', $filename;

    # From - <date> is required to be a valid mbox file.
    print TESTFILE "\n\nFrom - "
      . $email->header('Date') . "\n"
      . $email->as_string;
    close TESTFILE;
  }
  else {
    # This is useful for Sendmail, so we put it out here.
    local $ENV{PATH} = SENDMAIL_PATH;
    eval { sendmail($email, {transport => $transport}) };
    if ($@) {
      ThrowCodeError('mail_send_error', {msg => $@->message, mail => $email});
    }
  }

  # insert into email_rates
  if (Bugzilla->get_param_with_override('use_mailer_queue')
    && (EMAIL_LIMIT_PER_MINUTE || EMAIL_LIMIT_PER_HOUR))
  {
    $dbh->do(
      "INSERT INTO email_rates(recipient, message_ts) VALUES (?, LOCALTIMESTAMP(0))",
      undef, $email->header('To')
    );
  }
}

# Builds header suitable for use as a threading marker in email notifications
sub build_thread_marker {
  my ($bug_id, $user_id, $is_new) = @_;

  if (!defined $user_id) {
    $user_id = Bugzilla->user->id;
  }

  my $sitespec = '@' . Bugzilla->localconfig->urlbase;
  $sitespec =~ s/:\/\//\./;    # Make the protocol look like part of the domain
  $sitespec =~ s/^([^:\/]+):(\d+)/$1/;    # Remove a port number, to relocate
  if ($2) {
    $sitespec = "-$2$sitespec";    # Put the port number back in, before the '@'
  }

  my $threadingmarker = "References: <bug-$bug_id-$user_id$sitespec>";
  if ($is_new) {
    $threadingmarker .= "\nMessage-ID: <bug-$bug_id-$user_id$sitespec>";
  }
  else {
    my $rand_bits = generate_random_password(10);
    $threadingmarker .= "\nMessage-ID: <bug-$bug_id-$user_id-$rand_bits$sitespec>"
      . "\nIn-Reply-To: <bug-$bug_id-$user_id$sitespec>";
  }

  return $threadingmarker;
}

1;
