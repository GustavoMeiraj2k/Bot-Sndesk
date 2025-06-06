package GLPI::Agent::Task::Inventory::Win32::Users;

use strict;
use warnings;

use parent 'GLPI::Agent::Task::Inventory::Module';

use English qw(-no_match_vars);

use GLPI::Agent::Tools;
use GLPI::Agent::Tools::Win32;
use GLPI::Agent::Tools::Win32::Users;

use constant    other_categories
                            => qw(local_user local_group);
use constant    category    => "user";

sub isEnabled {
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    unless ($params{no_category}->{local_user}) {
        foreach my $user (getUsers(
            localusers  => 1,
            logger      => $logger
        )) {
            $inventory->addEntry(
                section => 'LOCAL_USERS',
                entry   => { map { $_ => $user->{$_} } qw/NAME ID/ }
            );
        }
    }

    unless ($params{no_category}->{local_group}) {
        foreach my $group (_getLocalGroups(logger => $logger)) {
            $inventory->addEntry(
                section => 'LOCAL_GROUPS',
                entry   => $group
            );
        }
    }

    # Handles seen users without being case sensitive
    my %seen = ();

    my $lastLoggedUser = _getLastUser(logger => $logger);
    if ($lastLoggedUser) {
        # Include last logged user as usual computer user
        if (ref($lastLoggedUser) eq 'HASH') {
            my $fullname = delete $lastLoggedUser->{_fullname};
            $fullname = $fullname ? lc($fullname) : lc($lastLoggedUser->{LOGIN}).'@'.lc($lastLoggedUser->{DOMAIN});
            $inventory->addEntry(
                section => 'USERS',
                entry   => $lastLoggedUser
            ) unless $seen{$fullname}++;

            # Obsolete in specs, to be removed with 3.0
            $inventory->setHardware({
                LASTLOGGEDUSER => $lastLoggedUser->{LOGIN}
            });
        } else {
            # Obsolete in specs, to be removed with 3.0
            $inventory->setHardware({
                LASTLOGGEDUSER => $lastLoggedUser
            });
        }
    }

    foreach my $user (_getLoggedUsers(logger => $logger)) {
        my $fullname = lc($user->{LOGIN}).'@'.lc($user->{DOMAIN});
        $inventory->addEntry(
            section => 'USERS',
            entry   => $user
        ) unless $seen{$fullname}++;
    }
}

sub _getLocalGroups {

    my $query =
        "SELECT * FROM Win32_Group " .
        "WHERE LocalAccount='True'";

    my @groups;

    foreach my $object (getWMIObjects(
        moniker    => 'winmgmts:\\\\.\\root\\CIMV2',
        query      => $query,
        properties => [ qw/Name SID/ ])
    ) {
        # Replace "right single quotation mark" by "simple quote" to avoid "Wide character in print" error
        $object->{Name} =~ s/\x{2019}/'/g;

        my $group = {
            NAME => $object->{Name},
            ID   => $object->{SID},
        };
        push @groups, $group;
    }

    return @groups;
}

sub _getLoggedUsers {

    my $query =
        "SELECT * FROM Win32_Process".
        " WHERE ExecutablePath IS NOT NULL" .
        " AND ExecutablePath LIKE '%\\\\Explorer\.exe'";

    my @users;
    my $seen;

    foreach my $user (getWMIObjects(
        moniker    => 'winmgmts:\\\\.\\root\\CIMV2',
        query      => $query,
        method     => 'GetOwner',
        params     => [ 'User', 'Domain' ],
        User       => [ 'string', '' ],
        Domain     => [ 'string', '' ],
        selector   => 'Handle', # For winrm support
        binds      => {
            User    => 'LOGIN',
            Domain  => 'DOMAIN'
        })
    ) {
        next if !defined($user->{LOGIN}) || $seen->{$user->{LOGIN}}++;

        push @users, $user;
    }

    return @users;
}

sub _getLastUser {
    my %params = @_;

    my $user;

    my ($system) = getWMIObjects(
        class      => 'Win32_ComputerSystem',
        properties => [ qw/Name UserName/ ],
        %params
    );
    if ($system && $system->{Name} && $system->{UserName}) {
        my $user = {
            DOMAIN  => $system->{UserName},
            LOGIN   => $system->{Name}
        };
        if ($user->{DOMAIN} =~ /^([^\\]*)\\(.*)$/) {
            $user->{DOMAIN} = $1 unless $1 eq '.';
            $user->{LOGIN}  = $2;
            # Handle AzureAD case
            if ($user->{DOMAIN} && $user->{DOMAIN} eq 'AzureAD') {
                my $upn = _getLastLoggedAzureADUserUPN(name => $user->{LOGIN}, %params);
                if ($upn && $upn =~ /^([^@]+)\@(.+)$/) {
                    $user->{_fullname} = $user->{LOGIN}.'@AzureAD';
                    $user->{LOGIN}     = $1;
                    $user->{DOMAIN}    = $2;
                }
            }
        }
        return $user;
    }

    return unless any {
        $user = getRegistryValue(path => "HKEY_LOCAL_MACHINE/$_", %params)
    } (
        'SOFTWARE/Microsoft/Windows/CurrentVersion/Authentication/LogonUI/LastLoggedOnSAMUser',
        'SOFTWARE/Microsoft/Windows/CurrentVersion/Authentication/LogonUI/LastLoggedOnUser',
        'SOFTWARE/Microsoft/Windows NT/CurrentVersion/Winlogon/DefaultUserName',
        'SOFTWARE/Microsoft/Windows NT/CurrentVersion/Winlogon/LastUsedUsername'
    );

    # LastLoggedOnSAMUser becomes the mandatory value to detect last logged on user
    if ($user =~ /^([^\\]*)\\(.*)$/) {
        $user = {
            DOMAIN  => $1,
            LOGIN   => $2
        };
        # Update domain if just a dot
        $user->{DOMAIN} = $system->{Name}
            if $user->{DOMAIN} eq '.' && $system && $system->{Name};
        if ($user->{DOMAIN} eq '.') {
            my ($useraccount) = getUsers(
                login => $user->{LOGIN},
                %params
            );
            $user->{DOMAIN} = $useraccount->{DOMAIN}
                if $useraccount;
        } elsif ($user->{DOMAIN} eq 'AzureAD') {
            # Handle AzureAD case
            my $upn = _getLastLoggedAzureADUserUPN(name => $user->{LOGIN}, %params);
            if ($upn && $upn =~ /^([^@]+)\@(.+)$/) {
                $user->{_fullname} = $user->{LOGIN}.'@AzureAD';
                $user->{LOGIN}     = $1;
                $user->{DOMAIN}    = $2;
            }
        }
    }

    return $user;
}

sub _getLastLoggedAzureADUserUPN {
    my %params = @_;

    my $sid = getRegistryValue(
        path => "HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/Windows/CurrentVersion/Authentication/LogonUI/LastLoggedOnUserSID",
        %params
    );
    return unless $sid;

    my $samname = getRegistryValue(
        path => "HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/IdentityStore/Cache/$sid/IdentityCache/$sid/SAMName",
        %params
    );
    return unless $samname && $params{name} && $samname eq $params{name};

    return getRegistryValue(
        path => "HKEY_LOCAL_MACHINE/SOFTWARE/Microsoft/IdentityStore/Cache/$sid/IdentityCache/$sid/UserName",
        %params
    );
}

1;
