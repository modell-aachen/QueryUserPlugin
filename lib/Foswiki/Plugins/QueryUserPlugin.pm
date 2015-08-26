# See bottom of file for default license and copyright information
package Foswiki::Plugins::QueryUserPlugin;

# Always use strict to enforce variable scoping
use strict;
use warnings;

use Foswiki::Func    ();
use Foswiki::Plugins ();
use Foswiki::Users   ();

our $VERSION = '0.1';
our $RELEASE = '0.1';
our $SHORTDESCRIPTION = 'Provides a macro to list/filter users.';
our $NO_PREFS_IN_TOPIC = 1;

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    Foswiki::Func::registerTagHandler( 'QUERYUSERS', \&_QUERYUSERS );
    #Foswiki::Func::registerRESTHandler( 'query', \&restQuery );
    return 1;
}

sub _filter {
    my ($filter, $fields, @list) = @_;
    my @parts = map { my $f = $_; sub { $_[0]{$f} =~ /$_[1]/i } } @$fields;
    return grep {
        my $o = $_;
        grep { $_->($o, $filter) } @parts
    } @list;
}

sub _users {
    my $session = shift;
    my $iter = $session->{users}->eachUser();
    my @res;
    while ($iter->hasNext) {
        my $u = $iter->next;
        push @res, {
            type => 'user',
            cUID => $u,
            loginName => $session->{users}->getLoginName($u),
            wikiName => $session->{users}->getWikiName($u),
            displayName => $session->{users}->can('getDisplayName') ? $session->{users}->getDisplayName($u) : $session->{users}->getWikiName($u),
            email => join(', ', $session->{users}->getEmails($u)),
        };
    }
    @res;
}

sub _groups {
    my $iter = Foswiki::Func::eachGroup();
    my @res;
    while ($iter->hasNext) {
        my $g = $iter->next;
        push @res, {
            type => 'group',
            cUID => $g,
            wikiName => $g,
        };
    }
    @res;
}

sub _QUERYUSERS {
    my ($session, $params, $topic, $web, $topicObject) = @_;

    my $filter = $params->{_DEFAULT};
    if ($params->{urlparam}) {
        my $q = $session->{request};
        $filter = $q->param($params->{urlparam});
    }
    my $exact = Foswiki::Func::isTrue($params->{exact});
    if ($exact || !Foswiki::Func::isTrue($params->{regex})) {
        $filter = quotemeta $filter;
    }
    $filter = '.*' if !defined $filter || $filter eq '';
    $filter = "^$filter\$" if $exact;

    my @fields = split(/\s*,\s*/, $params->{fields} || 'wikiName');

    my $type = $params->{type} || 'users';
    my $limit = $params->{limit} || 0;

    my @list;
    push @list, _users($session) if $type eq 'users' || $type eq 'any';
    push @list, _groups($session) if $type eq 'groups' || $type eq 'any';

    my $format = $params->{format} || '$wikiName';
    my $userformat = $params->{userformat} || $format;
    my $groupformat = $params->{groupformat} || $format;
    my $separator = $params->{separator} || ', ';
    my @out;
    for my $o (_filter($filter, \@fields, @list)) {
        my $entry = $o->{type} eq 'user' ? $userformat : $groupformat;
        $entry =~ s/\$cUID/$o->{cUID}/eg;
        $entry =~ s/\$loginName/$o->{loginName} || $o->{cuid}/eg;
        $entry =~ s/\$email/$o->{email} || ''/eg;
        $entry =~ s/\$wikiName/$o->{wikiName} || $o->{cuid}/eg;
        $entry =~ s/\$displayName/$o->{displayName} || $o->{cuid}/eg;
        push @out, $entry;
        last if $limit && @out >= $limit;
    }
    return Foswiki::Func::decodeFormatTokens(join($separator, @out));
}

sub restQuery {
   my ( $session, $subject, $verb, $response ) = @_;
   # TODO
}

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Author: %$AUTHOR%

Copyright (C) 2008-2013 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
