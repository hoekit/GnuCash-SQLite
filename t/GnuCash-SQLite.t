# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl GnuCash-SQLite.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use strict;
use warnings;
use DateTime;
use File::Copy qw/copy/;
use Try::Tiny;
use lib 'lib';

use Test::More tests => 22;
BEGIN { use_ok('GnuCash::SQLite') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my ($reader, $guid, $got, $exp, $msg);
$reader = GnuCash::SQLite->new(db => 't/sample.db');

try {
    my $book = GnuCash::SQLite->new();
} catch {
    tt('new() croaks if db parameter is undefined.',
        got => $_ =~ /No GnuCash file defined. at /,
        exp => 1 );
};

try {
    my $book = GnuCash::SQLite->new(db => 't/a-missing-file');
} catch {
    tt('new() croaks if db file is missing.',
        got => $_ =~ /File: t\/a-missing-file does not exist. at /,
        exp => 1 );
};

$guid = $reader->gen_guid();
tt('gen_guid() generates 32-characters',
    got => length($guid),
    exp => 32 );

tt('ccy_guid() found correct GUID.',
    got => $reader->ccy_guid('Assets:Cash'),
    exp => 'be2788c5c017bb63c859430612e64093');

tt('gen_post_date() generated correct timestamp.',
    got => $reader->gen_post_date('20140101'),
    exp => '20131231170000');

my $dt = DateTime->now();
tt('gen_enter_date() generated correct timestamp.',
    got => $reader->gen_enter_date(),
    exp => $dt->ymd('').$dt->hms(''));

tt('acct_guid() found correct GUID.',
    got => $reader->acct_guid('Assets:Cash'),
    exp => '6a86047e3b12a6c4748fbf8fde76c0c0');

tt('_guid_sql() returns correct SQL.',
    got => $reader->_guid_sql('Assets:Cash'),
    exp =>'SELECT guid FROM accounts WHERE name = "Cash" AND parent_guid = (SELECT guid FROM accounts WHERE name = "Assets" AND parent_guid = (SELECT guid FROM accounts WHERE name = "Root Account"))');

$guid = $reader->acct_guid('Assets');
tt('_child_guid() returns correct list of child guids.',
    got => join('--',sort @{$reader->_child_guid($guid)}),
    exp => join('--',('6a86047e3b12a6c4748fbf8fde76c0c0',
                      '6b870a6ef2c3fbbff0ec6df32108ac34')));

tt('_child_guid() returns empty list for leaf accounts.',
    got => join('--',sort @{$reader->_child_guid('Assets:Cash')}),
    exp => '');

$guid = $reader->acct_guid('Assets:Cash');
tt('_node_bal() returns correct balance.',
    got => $reader->_node_bal($guid),
    exp => 10000);

$guid = $reader->acct_guid('Assets:Cash');
tt('_guid_bal() returns correct balance for leaf accounts.',
    got => $reader->_guid_bal($guid),
    exp => 10000);

$guid = $reader->acct_guid('Assets');
tt('_guid_bal() returns correct balance for parent accounts.',
    got => $reader->_guid_bal($guid),
    exp => 15000);

tt('acct_bal() returns correct balance for leaf accounts.',
    got => $reader->acct_bal('Assets:Cash'),
    exp => 10000);

tt('acct_bal() returns correct parent accounts balances.',
    got => $reader->acct_bal('Assets'),
    exp => 15000 );

tt('acct_bal() returns undef for invalid account names.',
    got => $reader->acct_bal('No:Such:Account'),
    exp => undef );


#------------------------------------------------------------------
# Test the writer
#------------------------------------------------------------------

copy "t/sample.db", "t/scratch.db";
my $book = GnuCash::SQLite->new(db => 't/scratch.db');

my $cash_bal  = 10000;
my $bank_bal  =  5000;
my $asset_bal = 15000;

my $txn = {
    tx_date        => '20140102',
    tx_description => 'Deposit monthly savings',
    tx_from_acct   => 'Assets:Cash',
    tx_to_acct     => 'Assets:aBank',
    tx_amt         => 2540.15,
    tx_num         => ''
};

# Create a string that can be used in a regex match
$exp = hashref2str({
        tx_date         => '20140102',
        tx_description  => 'Deposit monthly savings',
        tx_from_acct    => 'Assets:Cash',
        tx_to_acct      => 'Assets:aBank',
        tx_amt          => 2540.15,
        tx_num          => '',
        tx_guid         => '.' x 32,    # some 32-char string
        tx_ccy_guid     => 'be2788c5c017bb63c859430612e64093',
        tx_post_date    => '20140101170000',
        tx_enter_date   => '\d' x 14,    # some 14-char numeric string
        tx_from_guid    => '6a86047e3b12a6c4748fbf8fde76c0c0',
        tx_to_guid      => '6b870a6ef2c3fbbff0ec6df32108ac34',
        tx_from_numer   => -254015,
        tx_to_numer     =>  254015,
        splt_guid_1     => '.' x 32,    # some 32-char string
        splt_guid_2     => '.' x 32     # some 32-char string 
    });
tt('_augment() adds correct set of data.',
    got => hashref2str($book->_augment($txn)) =~ /$exp/,
    exp => 1);

$book->add_txn($txn);

tt('add_txn() deducted from source account correctly.',
    got => $book->acct_bal('Assets:Cash'),
    exp => $cash_bal - $txn->{tx_amt} );

tt('add_txn() added to target account correctly.',
    got => $book->acct_bal('Assets:aBank'),
    exp => $bank_bal + $txn->{tx_amt} );

tt('add_txn() kept parent account (Assets) unchanged.',
    got => $book->acct_bal('Assets'),
    exp => $asset_bal );

tt('add_txn() does not clutter its input',
    got => join('|', sort keys %{$txn}),
    exp => 'tx_amt|tx_date|tx_description|tx_from_acct|tx_num|tx_to_acct');

#------------------------------------------------------------------
# A test utility
#------------------------------------------------------------------
# A function to allow rewriting the test to show the message first
# but when there are errors, the line number reported is not useful
sub tt {
    my $msg = shift;
    my %hash = @_;

    is($hash{got},$hash{exp},$msg);
}

# Given a hashref
# Return a string representation that's the same everytime
sub hashref2str {
    my $href = shift;
    my $result = '';

    foreach my $k (sort keys %{$href}) {
        $result .= "  $k - $href->{$k} \n"; 
    }
    return $result;
} 
