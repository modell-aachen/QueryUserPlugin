#!/usr/bin/perl
# Converter that rewrites user info from WikiName to cUID in various places:
# - Form fields
# - Workflow info (LASTPROCESSOR, LEAVING, WRKFLWCONTRIBUTORS)
# - ACLs
# - MetaCommentPlugin
#
# For form fields, only type 'user'/'user+multi' is processed, so you have to
# update the forms before running this.
#
# Only PlainFileStore is supported. Please convert before you do this.
#
# No arguments required.
# No backups are made; that's your job.

# Copyright 2015 Modell Aachen GmbH
# License: GPLv2+

use strict;
use warnings;

# Set library paths in @INC, at compile time
BEGIN {
  if (-e './setlib.cfg') {
    unshift @INC, '.';
  } elsif (-e '../bin/setlib.cfg') {
    unshift @INC, '../bin';
  }
  require 'setlib.cfg';
}

my %formcache;

use Foswiki ();
my $session = Foswiki->new('admin');

my %users;
my $usercount = 0;

# Rewrite a file (.txt or PFS version file)
sub treatFile {
    my ($web, $filename) = @_;

    open(my $tfh, '<:utf8', $filename) or warn("Can't open $filename: $!") && return;
    local $/;
    my $l = <$tfh>;

    my ($formraw) = $l =~ /^%META:FORM\{name="(.*?)"\}%$/m;
    my $fields = [];
    if ($formraw) {
        $formraw = "$web.$formraw" unless $formraw =~ /\./;
        $fields = $formcache{$formraw};
        if (!$fields) {
            $fields = [];
            my $form;
            eval {
                $form = Foswiki::Form->new($session, Foswiki::Func::normalizeWebTopicName(undef, $formraw));
            };
            unless ($@) {
                for my $f (@{$form->getFields}) {
                    next unless $f->isa('Foswiki::Form::User');
                    push @$fields, $f;
                }
            } else {
                print STDERR "Error loading form: `$formraw'";
            }
            $formcache{$formraw} = $fields;
        }
    }

    my $haswf = ($l =~ /^%META:WORKFLOW\{/m);

    my $origL = $l;
    close($tfh);
    for my $f (@$fields) {
        $l =~ s/^(%META:FIELD\{name="$f->{name}".*?value=")(.*)(".*\}%)$/$1. _mapUsersField($f, $2) .$3/em;
    }
    if ($haswf) {
        $l =~ s/^(%META:WORKFLOW\{)(.*)(\}%)$/$1. _mapTag($2, '^(?:LASTPROCESSOR_|LEAVING_)' => 0) .$3/em;
        $l =~ s/^(%META:WRKFLWCONTRIBUTORS\{)(.*)(\}%)$/$1. _mapTag($2, '^value$' => 1) .$3/em;
    }

    # Comments
    $l =~ s/^(%META:COMMENT\{)(.*)(\}%)$/$1. _mapTag($2, '^(?:read|notified)$' => 1, '^author$' => 0) .$3/egm;

    # Preferences
    $l =~ s/^(%META:PREFERENCE\{)(.*)(\}%)$/$1. _mapPrefValue($2, '^(?:ALLOW|DENY)TOPIC', 'value') .$3/egm;
    $l =~ s/^((?:   )+\*\s+Set\s+(\w+)\s+=\s+)([^\015\012]*)$/$1. _mapPref($2, $3)/egm;

    # Task changesets
    $l =~ s/^(%META:TASKCHANGESET\{)(.*)(\}%)$/$1. _mapTag($2, '^actor$' => 0) .$3/egm;

    return 1 if $l eq $origL;
    open($tfh, '>:utf8', $filename) or warn("Can't open $filename for writing: $!") && return;
    print $tfh $l;
    close($tfh);
    print STDERR "*";
    2;
}

# Map a single name to its cUID (unless it's unknown or already mapped).
sub _mapUser {
    my ($v) = @_;
    $v =~ s/^\s+|\s+$//g;
    my $shortV = $v =~ s/^(?:Main|%USERSWEB%)\.//r;
    return $users{$shortV} ? $users{$shortV} : $v;
}

# Map a comma-separated list of names to their cUIDs. Skip unknown/already mapped entries.
sub _mapUserMulti {
    my @v = map { _mapUser($_) } split(/\s*,\s*/, $_[0]);
    return join(', ', @v);
}

# Map a form field, automatically detecting multi-valuedness.
sub _mapUsersField {
    my ($f, $v) = @_;
    return _mapUserMulti($v) if $f->isMultiValued;
    return _mapUser($v);
}

# Rewrite the params list of a PREF tag.
# This gets passed a string, a matching pattern and the replace field.
# If a regex matches a value, the value of the given replace field would be mapped.
sub _mapPrefValue {
    my ($attrString, $match, $replace) = @_;
    my $attr = Foswiki::Attrs->new($attrString);
    while (my ($key, $value) = each(%$attr)) {
        next unless $value =~ /$match/;
        $attr->{$replace} = _mapUserMulti($attr->{$replace});
        last
    }
    return $attr->stringify;
}

# Rewrite the params list of a META tag or macro.
# This gets passed a regex->flag hash.
# If a regex matches, the multi-user mapping is applied if the flag is true; otherwise the single-user mapping is used.
sub _mapTag {
    my ($attrString, %map) = @_;
    my $attr = Foswiki::Attrs->new($attrString);
    while (my ($key, $value) = each(%$attr)) {
        while (my ($mk, $mv) = each(%map)) {
            next unless $key =~ /$mk/;
            if($mv){
                $attr->{$key} = _mapUserMulti($value);
            } else {
                $attr->{$key} = _mapUser($value);
            }
            last;
        }
    }
    $attr->stringify;
}

# Helper for mapping preferences in topic text
sub _mapPref {
    my ($pref, $v) = @_;

    return $v unless $pref =~ /^(?:ALLOW|DENY)(?:TOPIC|WEB|ROOT)/;
    _mapUserMulti($v);
}

my $uit = Foswiki::Func::eachUser();
while ($uit->hasNext) {
    my $u = $uit->next;
    my $cuid = Foswiki::Func::getCanonicalUserID($u);
    $users{$u} = $cuid;
    $usercount++;
}
print STDERR "Loaded information about $usercount users.\n";

my $keepmsg = 1;
for my $web (Foswiki::Func::getListOfWebs("user")) {
    TOPIC: for my $topic (Foswiki::Func::getTopicList($web)) {
        my $topicfile = "$Foswiki::cfg{DataDir}/$web/$topic.txt";
        my $pfvdir = "$Foswiki::cfg{DataDir}/$web/$topic,pfv";

        my $haspfv = -d $pfvdir;
        opendir(my $pfvh, $pfvdir) or warn("Can't read revisions dir $pfvdir: $!") if $haspfv;

        if (!$keepmsg) {
            print STDERR "\033[F\033[K";
        }
        $keepmsg = 0;
        print STDERR "$web.$topic: (current)";

        my $res = treatFile($web, $topicfile);
        $keepmsg = 1 if !$res || $res == 2;
        next unless $res;
        my $f;
        while ($haspfv and $f = readdir($pfvh)) {
            next unless $f =~ /^\d+$/;
            print STDERR "($f)";
            $res = treatFile($web, "$pfvdir/$f");
            $keepmsg = 1 if !$res || $res == 2;
            next TOPIC unless $res;
        }
        print STDERR ".\n";
    }
}
if (!$keepmsg) {
    print STDERR "\033[F\033[K";
}

print STDERR "\nDone.\n";
