# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::TryAutoLand::WebService;

use strict;
use warnings;

use base qw(Bugzilla::WebService);

use Bugzilla::Error;
use Bugzilla::Util qw(trick_taint);

use Bugzilla::Extension::TryAutoLand::Constants;

use constant READ_ONLY => qw(
    getBugs 
);

# TryAutoLand.getBugs
# returns a list of bugs, each being a hash of data needed by the AutoLand polling server
# [ { bug_id => $bug_id1, attachments => [ $attach_id1, $attach_id2 ] }, branches => $branchListFromTextField ... ]

sub getBugs { 
    my ($self, $params) = @_;
    my $user = Bugzilla->user;
    my $dbh  = Bugzilla->dbh;
    my %bugs;

    if ($user->login ne WEBSERVICE_USER) {
        ThrowUserError("auth_failure", { action => "access",
                                         object => "autoland_patches" });
    }

    my $attachments = $dbh->selectall_arrayref("
        SELECT attachments.bug_id, 
               attachments.attach_id, 
               autoland_attachments.who, 
               autoland_attachments.status,
               autoland_attachments.status_when 
          FROM attachments, autoland_attachments 
         WHERE attachments.attach_id = autoland_attachments.attach_id 
      ORDER BY attachments.bug_id");

    foreach my $row (@$attachments) {
        my ($bug_id, $attach_id, $al_who, $al_status, $al_status_when) = @$row;

        my $al_user = Bugzilla::User->new($al_who);

        # Silent Permission checks
        next if !$user->can_see_bug($bug_id);
        my $attachment = Bugzilla::Attachment->new($attach_id);
        next if !$attachment 
                || $attachment->isobsolete 
                || ($attachment->isprivate && !$user->is_insider);

        $bugs{$bug_id} = {} if !exists $bugs{$bug_id};

        $bugs{$bug_id}{'branches'} 
            = $dbh->selectrow_array("SELECT branches FROM autoland_branches 
                                      WHERE bug_id = ?", undef, $bug_id) || '';
       
        $bugs{$bug_id}{'attachments'} = [] if !exists $bugs{$bug_id}{'attachments'};

        push(@{$bugs{$bug_id}{'attachments'}}, {
            id          => $self->type('int', $attach_id),  
            who         => $self->type('string', $al_user->login), 
            status      => $self->type('string', $al_status), 
            status_when => $self->type('dateTime', $al_status_when), 
        });
    }

    return [ 
        map 
        { { bug_id => $_, attachments => $bugs{$_}{'attachments'}, branches => $bugs{$_}{'branches'} } }
        keys %bugs 
    ];
}

# TryAutoLand.updateStatus({ attach_id => $attach_id, status => $status })
# Let's BMO know if a patch has landed or not and BMO will update the auto_land table accordingly
# $status will be a predetermined set of pending/complete codes -- when pending, the UI for submitting 
# autoland will be locked and once complete status update occurs the UI can be unlocked and this entry 
# can be removed from tracking by WebService API 
# Allowed statuses: waiting, running, failed, or success

sub updateStatus { 
    my ($self, $params) = @_;
    my $user = Bugzilla->user;
    my $dbh  = Bugzilla->dbh;

    if ($user->login ne WEBSERVICE_USER) {
        ThrowUserError("auth_failure", { action => "modify",
                                         object => "autoland_patches" });
    }

    foreach my $param ('attach_id', 'status') {
        defined $params->{$param}
            || ThrowUserError('param_required', 
                              { param => $param });
    }

    my $attach_id = delete $params->{'attach_id'};
    my $status    = delete $params->{'status'};
 
    my $attachment = Bugzilla::Attachment->new($attach_id);
    ($attachment && !$attachment->isobsolete) 
        || ThrowUserError('autoland_invalid_attach_id',
                          { attach_id => $attach_id });
   
    # Loud Permission checks
    if (!$user->can_see_bug($attachment->bug_id)) {
        ThrowUserError("bug_access_denied", { bug_id => $attachment->bug_id });
    }
    if ($attachment->isprivate && !$user->is_insider) {
        ThrowUserError('auth_failure', { action    => 'access',
                                         object    => 'attachment',
                                         attach_id => $attachment->id });
    }

    $attachment->autoland_checked 
        || ThrowUserError('autoland_invalid_attach_id',
                          { attach_id => $attach_id });

    # Update the status
    $attachment->autoland_update_status($status);

    return { 
        id          => $self->type('int', $attachment->id),
        who         => $self->type('string', $attachment->autoland_who->login),
        status      => $self->type('string', $attachment->autoland_status),
        status_when => $self->type('dateTime', $attachment->autoland_status_when),
    };
}

1;
