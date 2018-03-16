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

our $SITEPREFS = {
  QUERYUSERS_DEFAULT_FIELDS => 'wikiName,displayName',
};

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.0 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    Foswiki::Func::registerTagHandler( 'RENDERUSER', \&_RENDERUSER );
    Foswiki::Func::registerTagHandler( 'QUERYUSERS', \&_QUERYUSERS );
    #Foswiki::Func::registerRESTHandler( 'query', \&restQuery );

    # Copy/Paste/Modify from MetaCommentPlugin
    # SMELL: this is not reliable as it depends on plugin order
    # if (Foswiki::Func::getContext()->{SolrPluginEnabled}) {
    if ($Foswiki::cfg{Plugins}{SolrPlugin}{Enabled}) {
      require Foswiki::Plugins::SolrPlugin;
      Foswiki::Plugins::SolrPlugin::registerIndexAttachmentHandler(
        \&indexAttachmentOrTopicHandler
      );
      Foswiki::Plugins::SolrPlugin::registerIndexTopicHandler(
        \&indexAttachmentOrTopicHandler
      );
    }

    return 1;
}

sub indexAttachmentOrTopicHandler {
    my ($indexer, $doc ) = @_; # note: this is used for attachments and topics

    my $author = $doc->value_for('author');
    return unless $author;

    my $session = $Foswiki::Plugins::SESSION;
    my $cUID = Foswiki::Func::getCanonicalUserID($author);
    my $info = _userinfo($session, $cUID);

    my $format = '$displayName';

    my $author_s = Foswiki::Func::decodeFormatTokens(_render($info, $format));
    $doc->add_fields( 'author_s', $author_s );
}

sub _filter {
    my ($filter, $fields, @list) = @_;
    my @parts = map {
        my $f = $_;
        sub {
            $_[0]{$f} && $_[0]{$f} =~ /$_[1]/i
        }
    } @$fields;
    return grep {
        my $o = $_;
        grep { $_->($o, $filter) } @parts
    } @list;
}

sub _userinfo {
    my ($session, $u) = @_;
    my $mapper = $session->{users}->_getMapping($u);
    my $wn = $session->{users}->getWikiName($u) || $u;
    return {
        type => 'user',
        cUID => $u,
        loginName => $session->{users}->getLoginName($u) || $u,
        wikiName => $wn,
        displayName => $mapper->can('getDisplayName') ? ($mapper->getDisplayName($u) || $wn) : $wn,
        email => join(', ', $session->{users}->getEmails($u)) || '',
    };
}

my $rewrite_attrubutes = {
    'cuid' => 'cUID',
    'loginname' => 'loginName',
    'wikiname' => 'wikiName',
    'displayname' => 'displayName'
};

sub _rewriteResult {
    my $entry = shift;

    while (my ($k, $v) = each %$rewrite_attrubutes) {
        next unless defined $entry->{$k};
        $entry->{$v} = $entry->{$k};
        delete $entry->{$k};
    }

    $entry;
}

sub _isUnifiedLogin {
    my $isUnifiedLogin = $Foswiki::cfg{LoginManager} eq 'Foswiki::LoginManager::UnifiedLogin';
    my $isSwitchableLoginWithUA = $Foswiki::cfg{LoginManager} eq 'Foswiki::LoginManager::SwitchableLogin' && $Foswiki::cfg{SwitchableLoginManagerContrib}{ActualLoginManager} eq 'Foswiki::LoginManager::UnifiedLogin';
    return $isUnifiedLogin || $isSwitchableLoginWithUA;
}

sub _usersUnified {
    my ($session, $basemapping, $opts, $userformat, $groupformat) = @_;
    my @res;
    require Foswiki::UnifiedAuth;
    my ($list, $count) = Foswiki::UnifiedAuth::new()->queryUser($opts);
    foreach my $entry (@$list) {
        $entry = _rewriteResult($entry);
        my $rendered;
        if ($entry->{type} eq 'user') {
            my $l = $entry->{loginName};
            unless (Foswiki::Func::isAnAdmin()) {
                delete $entry->{email} if $Foswiki::cfg{AntiSpam}{HideUserDetails} || Foswiki::Func::isGuest();
            }
            $rendered = _render($entry, $userformat);
        } else {
            delete $entry->{email};
            delete $entry->{loginName};
            delete $entry->{displayName};
            $rendered = _render($entry, $groupformat);
        }

        push @res, $rendered;
    }

    (\@res, $count);
}

sub _users {
    my $session = shift;
    my $basemapping = shift;
    my $iter = $session->{users}->eachUser();
    my @res;
    while ($iter->hasNext) {
        my $u = $iter->next;
        if ($u =~ /^BaseUserMapping_(\d+)$/) {
            next if $basemapping eq 'skip';
            next if $basemapping eq 'adminonly' && $1 ne '333';
        }
        push @res, _userinfo($session, $u);
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

sub _renderOneValue {
    my ($_text, $name, $val) = @_;
    $_[0] =~ s/\$json:$name/my $x = JSON->new->allow_nonref->encode($val); $x =~ s#^"##; $x =~ s#"$##; $x/eg;
    $_[0] =~ s/\$$name/$val/g;
}

sub _render {
    my ($o, $entry) = @_;
    $entry =~ s/\$pref\(($Foswiki::regex{tagNameRegex})(?:,([^\)]+))?\)/
        my ($tagName, $tagFallback) = ($1, $2);
        my $val = Foswiki::Func::getPreferencesValue($tagName);
        $val = $tagFallback unless $val || !defined $tagFallback;
        $val = '$displayName' unless $val;
        $val;
    /eg;
    _renderOneValue($entry, 'cUID', $o->{cUID});
    _renderOneValue($entry, 'loginName', $o->{loginName} || $o->{cUID});
    _renderOneValue($entry, 'email', $o->{email} || '');
    _renderOneValue($entry, 'wikiName', $o->{wikiName} || $o->{loginName} || $o->{cUID});
    _renderOneValue($entry, 'displayName', $o->{displayName} || $o->{wikiName} || $o->{loginName} || $o->{cUID});
    $entry;
}

sub _RENDERUSER {
    my ($session, $params, $topic, $web, $topicObject) = @_;

    my $cUID = $params->{_DEFAULT};
    $cUID = $session->{user} unless defined $cUID;
    my $type = $params->{type} || 'user';
    if ($type eq 'any') {
        $type = Foswiki::Func::isGroup($cUID) ? 'group' : 'user';
    }
    my $userIcon = $params->{usericon} || 0;

    my $info;
    if($cUID !~ m#\S#) {
        # %RENDERUSER{"" ...}% -> return (formatted) empty string
        $info = {
            type => $type,
            cUID => '',
            wikiName => '',
            displayName => '',
        };
    } elsif ($type eq 'user') {
        my $convert = $params->{convert};
        if (defined $params->{_DEFAULT} && (Foswiki::Func::isTrue($convert, 0) || $Foswiki::cfg{Plugins}{QueryUserPlugin}{ForceConvert})) {
            $cUID = Foswiki::Func::getCanonicalUserID($cUID);
        }
        $info = _userinfo($session, $cUID);
    } else {
        if(_isUnifiedLogin()) {
            my $mapper = $session->{users}->{mapping};
            $info = {
                type => 'group',
                cUID => $cUID,
                wikiName => $cUID,
                displayName => $mapper->getDisplayName($cUID) || $cUID,
            };
        } else {
            $info = {
                type => 'group',
                cUID => $cUID,
                wikiName => $cUID,
                displayName => $cUID,
            };
        }
    }

    my $format = $params->{format} || '$displayName';
    my $userformat = $params->{userformat} || $format;
    my $groupformat = $params->{groupformat} || $format;

    if($userIcon && $Foswiki::cfg{Plugins}{EmployeesAppPlugin}{Enabled} && Foswiki::Plugins::DefaultPreferencesPlugin::getSitePreferencesValue('EMPLOYEESAPP_USERICON')){
        require Foswiki::Plugins::EmployeesAppPlugin;
        $info->{displayName} = Foswiki::Plugins::EmployeesAppPlugin::renderUserWithIcon($session, $cUID, $topic, $web);
    }
    return Foswiki::Func::decodeFormatTokens(_render($info, $type eq 'user' ? $userformat: $groupformat));
}

sub _QUERYUSERS {
    my ($session, $params, $topic, $web, $topicObject) = @_;

    my $filter = $params->{_DEFAULT};
    my $ua_opts = {term => $filter};
    if ($params->{urlparam}) {
        my $q = $session->{request};
        $filter = $q->param($params->{urlparam});
        $ua_opts = {
            term => $filter || '',
            page => $q->param('page') || '',
            offset => $q->param('offset') || '',
        };
        my $limit = $q->param('limit');
        $ua_opts->{limit} = $limit if defined $limit;
    }
    my $originalFilter = $filter;
    my $exact = Foswiki::Func::isTrue($params->{exact});
    if ($filter && ($exact || !Foswiki::Func::isTrue($params->{regex}))) {
        $filter = quotemeta $filter;
    }
    $filter = '.*' if !defined $filter || $filter eq '';
    $filter = "^$filter\$" if $exact;

    my $defaultFields = Foswiki::Func::getPreferencesValue('QUERYUSERS_DEFAULT_FIELDS');
    my @fields = split(/\s*,\s*/, $params->{fields} || $defaultFields);
    push @{$ua_opts->{searchable_fields}}, @fields;

    my $type = $params->{type} || 'user';
    my $limit = $params->{limit} || 0;
    my $format = $params->{format} || '$displayName';
    my $userformat = $params->{userformat} || $format;
    my $groupformat = $params->{groupformat} || $format;
    my $separator = $params->{separator} || ', ';
    my $sort = $params->{sort} || '';
    my $basemapping = $params->{basemapping} || 'skip';

    my $count;
    my $out;
    if(_isUnifiedLogin()) {
        $ua_opts->{type} = $type;
        $ua_opts->{basemapping} = $basemapping;
        $ua_opts->{ingroup} = $params->{ingroup};
        $ua_opts->{limit} = $limit unless defined $ua_opts->{limit};
        ($out, $count) = _usersUnified($session, $basemapping, $ua_opts, $userformat, $groupformat);
    } else {
        my @list;
        $out = [];
        push @list, _users($session, $basemapping) if $type eq 'user' || $type eq 'any';
        push @list, _groups($session) if $type eq 'groups' || $type eq 'any';

        my @groupfilter = defined $params->{ingroup} ? split /,/, $params->{ingroup} : ();
        for my $o (_filter($filter, \@fields, @list)) {
            my $entry = _render($o, $o->{type} eq 'user' ? $userformat : $groupformat);
            if(@groupfilter && $o->{type} eq 'user'){
                foreach my $g (@groupfilter) {
                    if(Foswiki::Func::isGroupMember($g,$o->{loginName} || $o->{cUID})){
                        push @$out, $entry;
                        $count ++;
                        last;
                    }
                }
            }else{
                # XXX this will not go well when sorting into the users list
                push @$out, $entry unless $limit && @$out >= $limit;
                $count ++;
            }
        }
        if($sort eq 'asc' ){
            @$out = sort { $a cmp $b } @$out;
        }elsif($sort eq 'desc'){
            @$out = reverse(sort { $a cmp $b } @$out);
        }
    }

    my $formatted = Foswiki::Func::decodeFormatTokens(join($separator, @$out));

    my @result = ($formatted);
    if(defined $params->{header}) {
        my $header = $params->{header};
        $header = Foswiki::Func::decodeFormatTokens($header);
        $header =~ s#\$count#$count#g;
        unshift @result, $header;
    }

    if(defined $params->{footer}) {
        my $footer = $params->{footer};
        $footer = Foswiki::Func::decodeFormatTokens($footer);
        $footer =~ s#\$count#$count#g;
        push @result, $footer;
    }

    return join('', @result);
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
