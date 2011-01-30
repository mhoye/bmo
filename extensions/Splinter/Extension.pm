package Bugzilla::Extension::Splinter;

use strict;

use base qw(Bugzilla::Extension);

use Bugzilla;
use Bugzilla::Bug;
use Bugzilla::Template;
use Bugzilla::Attachment;
use Bugzilla::BugMail;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Field;
use Bugzilla::Util qw(trim detaint_natural);

use Bugzilla::Extension::Splinter::Util;

our $VERSION = '0.1';

sub page_before_template {
    my ($self, $args) = @_;

    my ($vars, $page) = @$args{qw(vars page_id)};
    my $input = Bugzilla->input_params;

    if ($page eq 'splinter.html') {

        Bugzilla->login(LOGIN_REQUIRED);

        if ($input->{'action'} eq 'publish') {
            my $user = Bugzilla->user;
            
            $input->{'attachment_id'}
                || ThrowCodeError('param_required', { param => 'attachment_id' });

            my $attachment = new Bugzilla::Attachment($input->{'attachment_id'});
            $attachment || ThrowUserError("invalid_attach_id",
                                          { attach_id => $input->{'attachment_id'} });
       
            Bugzilla::Bug->check($attachment->bug_id);
            if ($attachment->isprivate 
                && $user->id != $attachment->attacher->id
                && !$user->is_insider)
            {
                ThrowUserError('auth_failure', { action => 'access',
                                                 object => 'attachment' });
            }
        
            my $bug = $attachment->bug;

            ($input->{'review'} && trim($input->{'review'}) ne '')
                || ThrowCodeError('param_required', { param => 'review' });
        
            if ($input->{'attachment_status'}) {
                my $field_object = new Bugzilla::Field({ name => 'attachments.status' });
                my $legal_values = [map { $_->name } @{ $field_object->legal_values }];
                check_field('attachments.status', $input->{'attachment_status'}, $legal_values);
            }
        
            Bugzilla->user->can_edit_product($bug->product_id)
                || ThrowUserError("product_edit_denied", { product => $bug->product });
        
            my $comment = "Review of attachment " . $attachment->id . ":\n\n" . $input->{'review'};
        
            my $dbh = Bugzilla->dbh;
        
            my ($timestamp) = $dbh->selectrow_array("SELECT LOCALTIMESTAMP(0)");
        
            $bug->add_comment($comment);
        
            $dbh->bz_start_transaction();
        
            if ($input->{'attachment_status'} 
                && $attachment->status ne $input->{'attachment_status'}) 
            {
                $dbh->do("UPDATE attachments
                          SET    status      = ?,
                                 modification_time = ?
                          WHERE  attach_id   = ?",
                          undef, ($input->{'attachment_status'}, $timestamp, $attachment->id));
        
                my $updated_attachment = new Bugzilla::Attachment($attachment->id);
        
                if ($attachment->status ne $updated_attachment->status) {
                    my $fieldid = get_field_id('attachments.status');
                    $dbh->do('INSERT INTO bugs_activity (bug_id, attach_id, who, bug_when,
                                                       fieldid, removed, added)
                                   VALUES (?, ?, ?, ?, ?, ?, ?)',
                             undef, 
                             ($bug->id, $attachment->id, Bugzilla->user->id,
                              $timestamp, $fieldid, $attachment->status, 
                              $updated_attachment->status));
                }
            }
        
            my $changes = $bug->update();
        
            $dbh->bz_commit_transaction();
        
            my $vars = { title_tag => "bug_processed" };
            $bug->send_changes($changes, $vars);
        } 

        if ($input->{'bug'}) {
            $vars->{'bug_id'} = $input->{'bug'};
            $vars->{'attach_id'} = $input->{'attachment'};
            $vars->{'bug'} = Bugzilla::Bug->check($input->{'bug'});
        }

        my $field_object = new Bugzilla::Field({ name => 'attachments.status' });
        my $statuses;
        if ($field_object) {
            $statuses = [map { $_->name } @{ $field_object->legal_values }];
        } else {
            $statuses = [];
        }
        $vars->{'attachment_statuses'} = $statuses;
    }
}


sub bug_format_comment {
    my ($self, $args) = @_;
    
    my $bug = $args->{'bug'};
    my $regexes = $args->{'regexes'};
    my $text = $args->{'text'};
    
    # Add [review] link to the end of "Created attachment" comments
    #
    # We need to work around the way that the hook works, which is intended
    # to avoid overlapping matches, since we *want* an overlapping match
    # here (the normal handling of "Created attachment"), so we add in
    # dummy text and then replace in the regular expression we return from
    # the hook.
    $$text =~ s~((?:^Created\ |\b)attachment\s*\#?\s*(\d+)(\s\[details\])?)
               ~(push(@$regexes, { match => qr/__REVIEW__$2/,
                                   replace => get_review_link($bug, "$2", "[review]") })) &&
                (attachment_id_is_patch($2) ? "$1 __REVIEW__$2" : $1)
               ~egmx;
    
    # And linkify "Review of attachment", this is less of a workaround since
    # there is no issue with overlap; note that there is an assumption that
    # there is only one match in the text we are linkifying, since they all
    # get the same link.
    my $REVIEW_RE = qr/Review\s+of\s+attachment\s+(\d+)\s*:/;
    
    if ($$text =~ $REVIEW_RE) {
        my $review_link = get_review_link($bug, $1, "Review");
        my $attach_link = Bugzilla::Template::get_attachment_link($1, "attachment $1");
    
        push(@$regexes, { match => $REVIEW_RE,
                          replace => "$review_link of $attach_link:"});
    }
}

sub config_add_panels {
    my ($self, $args) = @_;

    my $modules = $args->{panel_modules};
    $modules->{Splinter} = "Bugzilla::Extension::Splinter::Config";
}

sub mailer_before_send {
    my ($self, $args) = @_;
    
    # Post-process bug mail to add review links to bug mail.
    # It would be nice to be able to hook in earlier in the
    # process when the email body is being formatted in the
    # style of the bug-format_comment link for HTML but this
    # is the only hook available as of Bugzilla-3.4.
    add_review_links_to_email($args->{'email'});
}

sub webservice {
    my ($self, $args) = @_;
    
    my $dispatch = $args->{dispatch};
    $dispatch->{Splinter} = "Bugzilla::Extension::Splinter::WebService";
}

__PACKAGE__->NAME;
