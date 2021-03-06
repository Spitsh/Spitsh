use Test;

plan 18;

{
    my File $file .= tmp;
    ok $file.exists,'.tmp';
    ok $file,'File.Bool = File.exists';
    $file.remove;
    nok $file.exists,'.remove';
    nok $file,'File.Bool = File.exists (false)';
    $file.touch;
    ok $file.exists,'.touch creates the file';
    CHECK-CLEAN nok $file.exists,"tempfiles should be rm by END";
}

{
    my File $file .= tmp;
    ok $file.writable,'.writable';
    ok $file.w, '.w';

    is $file, $file.write("foo"), '.write returns $self';

    is $file.slurp,"foo",".slurp .write";
    is $file.size,3,'.size';
    is $file.s,3,'.s';

    $file.append("bar");
    is $file.slurp,"foobar",'.append';

    $file.push("baz");
    is $file.slurp,"foobar\nbaz", ‘.push puts a newline if there isn't one’;
    is $file.slurp.${cat},"foobar\nbaz",'.slurp.${cat}';

    is $file.size,11,'.size changes after appending';

    $file.push('%s');
    is $file.slurp, "foobar\nbaz\n%s", ‘.push('%s')’;

    CHECK-CLEAN nok $file.exists,"tempfiles should be rm by END";
}
