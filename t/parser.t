use Test::Most 0.22;
use Test::FailWarnings;
use utf8;

use Try::Tiny;
use RedisDB::Parser;
use RedisDB::Parser::PP;

my $lf        = "\015\012";
my $parser_pp = RedisDB::Parser::PP->new();

subtest "Pure Perl Implementation" => sub { test_parser($parser_pp) };

my $xs = try { require RedisDB::Parser::XS; 1; };

my $parser_xs = RedisDB::Parser->new;

if ($xs) {
    is( RedisDB::Parser->implementation,
        "RedisDB::Parser::XS", "XS implementation loaded" );
    isa_ok $parser_xs, "RedisDB::Parser::XS", "Got XS version of the object";
    subtest "XS Implementation" => sub { test_parser($parser_xs) };
}
else {
    diag "\n";
    diag "#" x 40;
    diag "\n   Could not load XS implementation,\n   Testing PP implementation only\n\n";
    diag "#" x 40;
    isa_ok $parser_xs, "RedisDB::Parser::PP", "Got PP version of the object";
}

done_testing;

# parser test follows

my $parser;

sub test_parser {
    $parser = shift;
    subtest "Request encoding"             => \&request_encoding;
    subtest "One line reply"               => \&one_line_reply;
    subtest "Integer reply"                => \&integer_reply;
    subtest "Bulk reply"                   => \&bulk_reply;
    subtest "Multi-bulk reply"             => \&multi_bulk_reply;
    subtest "Deep nested multi-bulk reply" => \&nested_mb_reply;
    subtest "Transaction"                  => \&transaction;
    subtest "Propagate reply"              => \&propagate_reply;
    done_testing;
}

sub request_encoding {
    my $command = 'test';
    my $int     = 12;
    my $string  = "Short string for testing";
    my $ustring = "上得山多终遇虎";

    use bytes;
    my $binary =
      "Some strings may contain\n linebreaks\0 \r\n or zero terminated strings\0 or some latin1 chars \110";

    eq_or_diff(
        $parser->build_request('test'),
        join( $lf, '*1', '$4', 'test', '' ),
        "Single command is ok"
    );
    eq_or_diff( $parser->build_request( $command, $int ),
        join( $lf, '*2', '$4', 'test', '$2', '12', '' ), "Integer" );
    eq_or_diff(
        $parser->build_request( $command, $string ),
        join( $lf, '*2', '$4', 'test', '$24', $string, '' ),
        "ASCII string"
    );
    my $ulen = length $ustring;
    ok $ulen > 7, "Length is in bytes";
    eq_or_diff(
        $parser->build_request( $command, $ustring, $string ),
        join( $lf, '*3', '$4', 'test', "\$$ulen", $ustring, '$24', $string, '' ),
        "unicode string"
    );
    my $blen = length $binary;
    eq_or_diff(
        $parser->build_request( $command, $binary, $ustring ),
        join( $lf, '*3', '$4', 'test', "\$$blen", $binary, "\$$ulen", $ustring, '' ),
        "binary string"
    );
}

my @replies;

sub cb {
    shift;
    push @replies, shift;
}

sub one_line_reply {
    @replies = ();
    $parser->push_callback( \&cb ) for 1 .. 5;
    is $parser->callbacks, 5, "Five callbacks were added";
    $parser->parse("+");
    is @replies, 0, "+";
    is $parser->parse("OK"), 0, "parse returned 0";
    is @replies, 0, "+OK";
    is $parser->parse("\015"), 0, "parse returned 0";
    is @replies, 0, "+OK\\r";
    is $parser->parse("\012+And here we have something long$lf-ERR"), 2,
      "parse returned 2";
    is @replies, 2, "Found 2 replies";
    is $parser->callbacks, 3, "Three callbacks left";
    eq_or_diff \@replies, [ "OK", "And here we have something long" ],
      "OK, And here we have something long";
    @replies = ();
    is $parser->parse(
        " error$lf-MOVED 7777 127.0.0.2:3333$lf-ASK 8888 127.0.0.2:4444$lf"), 3,
      "parse returned 3";
    is @replies, 3, "Got 3 replies";
    isa_ok $replies[0], "RedisDB::Parser::Error", "Got an error object";
    is $replies[0]{message}, 'ERR error', 'correct error message';
    isa_ok $replies[1], "RedisDB::Parser::Error::MOVED",
      "Got an MOVED error object";
    is $replies[1]{slot}, 7777,        'correct slot';
    is $replies[1]{host}, '127.0.0.2', 'correct host';
    is $replies[1]{port}, '3333',      'correct port';
    isa_ok $replies[2], "RedisDB::Parser::Error::ASK",
      "Got an ASK error object";
    is $replies[2]{slot}, 8888,        'correct slot';
    is $replies[2]{host}, '127.0.0.2', 'correct host';
    is $replies[2]{port}, '4444',      'correct port';
}

sub integer_reply {
    @replies = ();
    $parser->push_callback( \&cb ) for 1 .. 3;
    $parser->parse(":");
    is @replies, 0, ":";
    $parser->parse("12");
    is @replies, 0, ":12";
    $parser->parse("34$lf");
    is @replies, 1, "Got a reply";
    eq_or_diff shift(@replies), 1234, "got 1234";
    $parser->parse(":0$lf:-123$lf");
    is @replies, 2, "Got two replies";
    eq_or_diff \@replies, [ 0, -123 ], "got 0 and -123";
    my $class = ref $parser;
    # TODO: this is wrong
    my $parser2 = $class->new();
    dies_ok { $parser2->parse(":123a$lf") } "Dies on invalid integer reply";
}

sub bulk_reply {
    @replies = ();
    $parser->push_callback( \&cb ) for 1 .. 3;
    $parser->parse('$');
    is @replies, 0, '$';
    $parser->parse("6${lf}foobar");
    is @replies, 0, '$6\\r\\nfoobar';
    $parser->parse("${lf}\$-1${lf}\$0$lf$lf");
    is @replies, 3, "Got three replies";
    eq_or_diff \@replies, [ 'foobar', undef, '' ], "Got foobar, undef, and empty string";
}

sub multi_bulk_reply {
    @replies = ();
    $parser->push_callback( \&cb ) for 1 .. 4;
    $parser->parse("*4$lf\$3${lf}foo$lf\$");
    is @replies, 0, '*4$3foo$';
    $parser->parse("-1${lf}\$0$lf$lf\$5${lf}Hello");
    is @replies, 0, '*4$3foo$-1$0$5Hello';
    $parser->parse($lf);
    is @replies, 1, "Got a reply";
    eq_or_diff shift(@replies), [ 'foo', undef, '', 'Hello' ], 'got correct reply foo/undef//Hello';
    $parser->parse("*0$lf*-1$lf");
    is @replies, 2, "Got two replies";
    eq_or_diff \@replies, [ [], undef ], "*0 is empty list, *-1 is undef";

    # redis docs don't say that this is possible, but that's what I got
    @replies = ();
    $parser->parse("*3$lf\$9${lf}subscribe$lf\$3${lf}foo$lf:2$lf");
    is @replies, 1, "Got a reply";
    eq_or_diff $replies[0], [qw(subscribe foo 2)], 'subscribe foo :2';
}

sub nested_mb_reply {
    @replies = ();
    $parser->push_callback( \&cb );
    $parser->parse( "*3${lf}"
          . "*4${lf}:5${lf}:1336734898${lf}:43${lf}"
          . "*2${lf}\$3${lf}get${lf}\$4${lf}test${lf}"
          . "*4${lf}:4${lf}:1336734895${lf}:175${lf}"
          . "*3${lf}\$3${lf}set${lf}\$4${lf}test${lf}\$2${lf}43${lf}" );
    is @replies, 0, 'waits for the last chunk';
    $parser->parse(
        "*4${lf}:3${lf}:1336734889${lf}:20${lf}" . "*3${lf}\$7${lf}slowlog${lf}*2${lf}:1${lf}:2${lf}\$3${lf}len${lf}" );
    is @replies, 1, "Got a reply";
    my $exp = [
        [ 5, 1336734898, 43,  [ 'get',     'test' ], ],
        [ 4, 1336734895, 175, [ 'set',     'test', '43' ], ],
        [ 3, 1336734889, 20,  [ 'slowlog', [1, 2 ], 'len', ], ],
    ];
    eq_or_diff shift(@replies), $exp, 'got correct nested multi-bulk reply';
}

sub transaction {
    @replies = ();
    $parser->push_callback( \&cb ) for 1 .. 4;
    $parser->parse("*7$lf+OK$lf:5$lf:6$lf:7$lf:8$lf*4$lf\$4$lf");
    is @replies, 0, 'Incomplete result - not parsed';
    $parser->parse("this$lf\$2${lf}is$lf\$1${lf}a$lf\$4${lf}list$lf");
    is @replies, 0, 'After encapsulated multi-bulk part - still not parsed';
    $parser->parse("\$5${lf}value$lf");
    is @replies, 1, 'Got a reply';
    eq_or_diff(
        shift(@replies),
        [ 'OK', 5, 6, 7, 8, [qw(this is a list)], 'value' ],
        "Successfuly parsed a transaction reply"
    );
    $parser->parse(
        "*6$lf+OK$lf:1$lf:2$lf:3$lf:4$lf*4$lf\$4${lf}this$lf\$2${lf}is${lf}\$1${lf}a$lf\$4${lf}list$lf"
    );
    is @replies, 1, 'Got a reply';
    eq_or_diff(
        shift(@replies),
        [ 'OK', 1, 2, 3, 4, [qw(this is a list)] ],
        "Parsed with list in the end too"
    );
    $parser->parse("*4$lf*0$lf+OK$lf*-1$lf*2$lf\$2${lf}aa$lf\$2${lf}bb$lf");
    is @replies, 1, 'Got a reply';
    eq_or_diff shift(@replies), [ [], 'OK', undef, [qw(aa bb)] ],
      "Parsed reply with empty list and undef";
    $parser->parse("*3$lf*0$lf-ERR Oops$lf+OK$lf");
    is @replies, 1, 'Got a reply with error inside';
    my $reply = shift @replies;
    eq_or_diff $reply->[0], [], "  has empty list";
    isa_ok $reply->[1], "RedisDB::Parser::Error", "  has error object";
    is "$reply->[1]", "ERR Oops", "ERR Oops";
    is $reply->[2], "OK", "  has OK";
}

sub propagate_reply {
    @replies = ();
    for my $var ( 1 .. 3 ) {
        $parser->push_callback( sub { push @replies, [ $var, "$_[1]" ] } );
    }
    $parser->set_default_callback( sub { push @replies, [ 0, "$_[1]" ] } );
    $parser->propagate_reply( RedisDB::Parser::Error->new("ERR Oops") );
    ok ! $parser->callbacks, "No callbacks in the queue";
    eq_or_diff [ sort { $a->[0] <=> $b->[0] } @replies ], [ map { [ $_, "ERR Oops" ] } 0 .. 3 ], "All callbacks got the error";
}
