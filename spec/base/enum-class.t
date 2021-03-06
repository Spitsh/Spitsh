use Test;

plan 19;

enum-class Biological-Class { }

enum-class Mamalia is Biological-Class { }
enum-class Maxillopoda is Biological-Class { }
enum-class Sauropsida  is Biological-Class { }

enum-class Prototheria is Mamalia { }
enum-class Marsupial   is Mamalia { }

enum-class Copepod is Maxillopoda { }
enum-class Thecostraca is Maxillopoda { }

enum-class Parareptilia is Sauropsida { }
enum-class Eureptilia   is Sauropsida { }

enum-class Kangaroo is Marsupial { }
enum-class Wombat   is Marsupial { }

ok Mamalia ~~ Biological-Class,'Mamalia ~~ Biological-Class';
nok Mamalia ~~ Sauropsida,'Mamalia !~~ Sauropsida';

ok Marsupial ~~ Mamalia,'Marsupial ~~ Mamalia';
ok Marsupial ~~ Biological-Class,'Marsupial ~~ Biological-Class';
ok Kangaroo  ~~ Mamalia,'Kangaroo ~~ Mamalia';
ok Kangaroo ~~ Biological-Class,'Kangaroo ~~ Biological-Class';

{
    my Biological-Class $mamals = Mamalia;
    my Biological-Class $marsupials = Marsupial;
    my Biological-Class $kangaroos   = Kangaroo;
    my Biological-Class $copepods    = Copepod;
    my Biological-Class $sauropsida  = Sauropsida;

    ok Kangaroo ~~ $mamals,'Kangaroo ~~ $mamals';
    # These two used to be ~~ but that will have to wait unitl multi methods
    ok $mamals.has-member('Kangaroo'),'"Kangaroo" ~~ $mamals';
    nok $mamals.has-member('Kangaroot'),'"Kangaroot" !~~ $mamals';
    nok $mamals ~~ $kangaroos,'$mamals !~~ $kangaroos';
    ok $kangaroos ~~ $mamals,'$kangaroos ~~ $mamals';
    ok $marsupials ~~ $mamals,'$marsupials ~~ $mamals';
    nok $mamals ~~ $marsupials,'$mamals !~~ $marsupials';
    nok $kangaroos ~~ $copepods, '$kangaroos !~~ $copepods';
    nok $copepods ~~ $mamals, '$copepods !~~ $mamals';
    is $mamals.name,"Mamalia",'.name';

    my Biological-Class $c = Marsupial;
    given $c {
        when Sauropsida { flunk 'given/when with enum-class' }
        when Mamalia     { pass 'given/when with enum-class' }
        when Maxillopoda { flunk 'given/when with enum-class' }
        default { flunk 'given/when with enum-class' }
    }
}

sub test-enum(Biological-Class $a, Biological-Class $b) {
    ok $a ~~ $b, "in sub call: {$a.name} ~~ {$b.name}";
}

test-enum Kangaroo, Mamalia;
test-enum Mamalia, Biological-Class;
