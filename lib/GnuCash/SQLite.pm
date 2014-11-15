package GnuCash::SQLite;

use strict;
use warnings;
use 5.10.0;
use UUID::Tiny ':std';
use DBI;
use DateTime;
use Carp;
use Path::Tiny;
use Data::Dumper;

our $VERSION = '0.01';

sub new {
    my $class = shift;
    my %attr = @_;
    my $self = {};

    croak 'No GnuCash file defined.'
        unless defined($attr{db});
    croak "File: $attr{db} does not exist."
        unless path($attr{db})->is_file;
    $self->{db} = $attr{db};
    $self->{dbh} = DBI->connect("dbi:SQLite:dbname=$self->{db}","","");

    bless $self, $class;
    return $self;
}

# Generate a 32-character UUID
sub gen_guid {
    my $uuid = create_uuid_as_string(UUID_V1);
    $uuid =~ s/-//g;
    return $uuid;
}

# Given an account name, return the GUID of the currency associated with that
# account
sub ccy_guid {
    my $self = shift;
    my $acct = shift;

    my $sql = "SELECT commodity_guid FROM accounts "
            . "WHERE guid = (".$self->_guid_sql($acct).")";
    return $self->_runsql($sql)->[0][0];
}

# Given a date in YYYYMMDD format, 
# This is always in the local timezone
# And GnuCash stores all dates in UTC timezone
# This function needs to:
#   1. Create a date time with the local timezone
#   2. Switch to the UTC timezone
#   3. Store that timestamp
# For example, the 'Asia/Bangkok' timezone is UTC +7:00
#   given txn date of 20140101 (in the local timezone)
#   return 20131231170000 (which gets stored in the db)
sub gen_post_date {
    my $self = shift;
    my ($YYYY, $MM, $DD) = (shift =~ /(....)(..)(..)/);

    # Create a new 
    my $dt = DateTime->new(
        year      => $YYYY,
        month     => $MM,
        day       => $DD,
        time_zone => 'local' );
    $dt->set_time_zone('UTC');
    return $dt->ymd('') . $dt->hms('');

    $dt->subtract(days => 1);
    return $dt->ymd('') . '170000';
}

# Returns the system date in YYYYMMDDhhmmss format
# Timezone is UTC (GMT 00:00)
sub gen_enter_date {
    my $dt = DateTime->now();
    return $dt->ymd('').$dt->hms('');
}

# Given an account name, return the GUID of the account
sub acct_guid {
    my $self = shift;
    my $acct_name = shift;

    my $sql = $self->_guid_sql($acct_name);
    return $self->_runsql($sql)->[0][0];
}

# Given an account name, return the SQL that reads its GUID
# Generate a recursive SQL given the full account name e.g. Assets:Cash
# A naive implementation may just extract the tail account
#    i.e. SELECT guid FROM accounts WHERE name = 'Cash';
# That fails when accounts of the same name have different parents
#    e.g. Assets:Husband:Cash and Assets:Wife:Cash
sub _guid_sql {
    my $self = shift;
    my ($acct_name) = @_;
    my $sub_sql = 'SELECT guid FROM accounts WHERE name = "Root Account"';
    foreach my $acct (split ":", $acct_name) {
        $sub_sql = 'SELECT guid FROM accounts '
                 . 'WHERE name = "'.$acct.'" '
                 . 'AND parent_guid = ('.$sub_sql.')';
    }
    return $sub_sql;
}

# Given a guid, return a list of child guids or if none, an empty arrayref
sub _child_guid {
    my $self = shift;
    my $parent_guid = shift;

	my $sql = qq/SELECT guid FROM accounts WHERE parent_guid = "$parent_guid"/;

    # The map belows converts [[x],[y],[z]] into [x,y,z]
    my @res = map { $$_[0] } @{ $self->_runsql($sql) };
    return \@res;
}

# Given an account guid, 
# Return the balance at that guid, ignoring child accounts if any.
sub _node_bal {
    my $self = shift;
    my $guid = shift;

    my $sql = "SELECT SUM(value_num/(value_denom*1.0)) FROM splits "
            . "WHERE account_guid = ?";
    return $self->_runsql($sql,$guid)->[0][0] || 0;
}

# Recursive accumulator
sub _guid_bal {
    my $self = shift;
    my $guid = shift;
    my $bal = shift || 0;

	# Accumulate balances in child accounts
	foreach my $g (@{$self->_child_guid($guid)}) {
		$bal += $self->_guid_bal($g);
	}
	
	# Add balance in node and return
	return $bal + $self->_node_bal($guid);
}

# Given an account name, 
# Return the balance in that account, include child accounts, if any
sub acct_bal {
    my $self = shift;
    my $acct_name = shift;
    
    my $guid = $self->acct_guid($acct_name);
    return undef unless defined ($guid);
    return $self->_guid_bal($guid);
}

# Add a transaction to the GnuCash.
# Transaction is a hashref e.g.:
#
#   my $txn = {
#       tx_date        => '20140102',
#       tx_description => 'Deposit monthly savings',
#       tx_from_acct   => 'Assets:Cash',
#       tx_to_acct     => 'Assets:aBank',
#       tx_amt         => 2540.15,
#       tx_num         => ''
#   };
#
# To effect the transaction, do the following:
#   1. Add 1 row to transactions table
#   2. Add 2 rows to splits table
#   3. Add 1 row to slots table
# See
# http://wideopenstudy.blogspot.com/2014/11/how-to-add-transaction-programmatically.html
sub add_txn {
    my $self = shift;
    my $txn = shift;

    # augment the transaction with needed data
    $txn = $self->_augment($txn);

    # List the SQLs
    my $txn_sql  = 'INSERT INTO transactions VALUES (?,?,?,?,?,?)';
    my $splt_sql = 'INSERT INTO splits VALUES '
                 . ' (?,?,?,"","","n","",?,100,?,100,null)';
    my $slot_sql = 'INSERT INTO slots (obj_guid,name,slot_type,int64_val,'
                 . '                   string_val,double_val,timespec_val,'
                 . '                   guid_val,numeric_val_num,'
                 . '                   numeric_val_denom,gdate_val) '
                 . 'VALUES (?,"date-posted",10,0,"",0.0,"","",0,1,?)';
                 # This SQL form because slots has auto-increment field

    # Run the SQLs
    $self->_runsql($txn_sql, map { $txn->{$_} }
        qw/tx_guid tx_ccy_guid tx_num tx_post_date tx_enter_date
           tx_description /);
    $self->_runsql($splt_sql, map { $txn->{$_} }
        qw/splt_guid_1 tx_guid tx_from_guid tx_from_numer tx_from_numer/);
    $self->_runsql($splt_sql, map { $txn->{$_} }
        qw/splt_guid_2 tx_guid tx_to_guid tx_to_numer tx_to_numer/);
    $self->_runsql($slot_sql, map { $txn->{$_} }
        qw/tx_guid tx_date/);
}

# Augment the transaction with data required to generate data rows
sub _augment {
    my $self = shift;
    my $txn_orig = shift;

    # Make a copy of the original transaction so as not to clobber it
    # Copy only the fields needed
    my $txn = {};
    map { $txn->{$_} = $txn_orig->{$_} } (
        qw/tx_date tx_description tx_from_acct tx_to_acct tx_amt tx_num/);

    $txn->{tx_guid}       = $self->gen_guid();
    $txn->{tx_ccy_guid}   = $self->ccy_guid($txn->{tx_from_acct});
    $txn->{tx_post_date}  = $self->gen_post_date($txn->{tx_date});
    $txn->{tx_enter_date} = $self->gen_enter_date();
    $txn->{tx_from_guid}  = $self->acct_guid($txn->{tx_from_acct});
    $txn->{tx_to_guid}    = $self->acct_guid($txn->{tx_to_acct});
    $txn->{tx_from_numer} = $txn->{tx_amt} * -100;
    $txn->{tx_to_numer}   = $txn->{tx_amt} *  100;
    $txn->{splt_guid_1}   = $self->gen_guid();
    $txn->{splt_guid_2}   = $self->gen_guid();

    return $txn;
}

# Given an SQL statement and optionally a list of arguments
# execute the SQL with those arguments
sub _runsql {
    my $self = shift;
    my ($sql,@args) = @_;

    my $sth = $self->{dbh}->prepare($sql);
    $sth->execute(@args);
    my $data = $sth->fetchall_arrayref();
    $sth->finish;

    return $data;
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

  GnuCash::SQLite - A module to access GnuCash SQLite files

=head1 VERSION

  version 0.01

=head1 SYNOPSIS

  use GnuCash::SQLite;

  # create the book
  $book = GnuCash::SQLite->new(db => 'my_accounts.gnucash');

  # get account balances
  $book->acct_bal('Assets:Cash');   # always provide account names in full
  $book->acct_bal('Assets');        # includes child accounts e.g. Assets:Cash

  # add a transaction
  $book->add_txn({
      tx_date        => '20140102',
      tx_description => 'Deposit monthly savings',
      tx_from_acct   => 'Assets:Cash',
      tx_to_acct     => 'Assets:aBank',
      tx_amt         => 2540.15,
      tx_num         => ''
  });

  # access internal GUIDs
  $book->acct_guid('Assets:Cash');  # GUID of account
  $book->ccy_guid('Assets:Cash');   # GUID of currency 

=head1 DESCRIPTION

GnuCash::SQLite provides an API to read account balances and write
transactions against a GnuCash set of accounts (only SQLite3 backend
supported).

When using the module, always provide account names in full e.g. "Assets:Cash"
rather than just "Cash". This lets the module distinguish between accounts
with the same name but different parents e.g. Assets:Misc and
Expenses:Misc

=head1 METHODS

=head2 Constructor

  $book = GnuCash::SQLite->new(db => 'my_account.gnucash');

Returns a new C<GnuCash::SQLite> object that accesses a GnuCash with and
SQLite backend. The module assumes you have already created a GnuCash file
with an SQLite backend and that is the file that should be passed as the
parameter.

If no file parameter is passed, or if the file is missing, the program will
terminate.

=head2 acct_bal

  $book->acct_bal('Assets:Cash');   # always provide account names in full
  $book->acct_bal('Assets');        # includes child accounts e.g. Assets:Cash

Given an account name, return the balance in the account. Account names must
be provided in full to distinguish between accounts with the same name but
different parents e.g. Assets:Alice:Cash and Assets:Bob:Cash

If a parent account name is provided, the total balance, which includes all
children accounts, will be returned.

=head2 add_txn

  $deposit = {
      tx_date        => '20140102',
      tx_description => 'Deposit monthly savings',
      tx_from_acct   => 'Assets:Cash',
      tx_to_acct     => 'Assets:aBank',
      tx_amt         => 2540.15,
      tx_num         => ''
  };
  $book->add_txn($deposit);

A transaction is defined to have the fields as listed in the example above.
All fields are mandatory and hopefully self-explanatory. Constraints on some
of the fields are listed below:

    tx_date         Date of the transaction. Formatted as YYYYMMDD.
    tx_from_acct    Full account name required.
    tx_to_acct      Full account name required.


=head1 CAVEATS/LIMITATIONS

Some things to be aware of:

    1. You should have created a GnuCash file with an SQLite backend already
    2. Module accesses the GnuCash SQLite3 db directly; i.e. use at your own risk.
    3. Only transactions between Asset accounts have been tested.
    4. Only two (2) splits for each transaction will be created

This module works with GnuCash v2.4.13 on Linux.

=head1 SEE ALSO

GnuCash wiki pages includes a section on C API and a section on Python
bindings which may be of interest.

    C API          : http://wiki.gnucash.org/wiki/C_API
    Python bindings: http://wiki.gnucash.org/wiki/Python_Bindings

This module does not rely on the C API (maybe it should). Instead it relies on
some reverse engineering work to understand the changes a transaction makes
to the sqlite database. See
http://wideopenstudy.blogspot.com/search/label/GnuCash for details.

=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker at
L<https://github.com/hoekit/GnuCash-SQLite/issues>. You will be notified
automatically of any progress on your issue.

=head2 Source Code

This is open source software. The code repository is available for public
review and contribution under the terms of the license.

    <https://github.com/hoekit/GnuCash-SQLite>

    git clone git@github.com:hoekit/GnuCash-SQLite.git

=head1 AUTHOR

Hoe Kit CHEW, E<lt>hoekit at gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 by Chew Hoe Kit

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
