unit class Spit::Actions;
use Spit::SAST;
use Spit::Constants;
use Spit::Exceptions;
need Spit::Metamodel;

has $.debug;
has $.use-bootstrap-types;

# work around RT #132512
sub _ast($match is raw) {
    use nqp;
    return nqp::getattr(nqp::decont($match), Match,'$!made');
}

method e ($/) { make $<wrapped>.ast }

method TOP($/){
    $*CURPAD.append: ($<statementlist>.ast // ());
    my $tmp = $*CU;
    make $tmp;
}

method newpad($/) {
    my $new = SAST::Block.new;
    $new.outer = $_ with CALLERS::<$*CURPAD>;
    $*CURPAD = $new;
}

method finishpad($/){
    $*CURPAD .= outer;
}

method newCU($/) {
    if $*SETTING {
        $*CURPAD.outer = $*SETTING;
    }
    else {
        $*SETTING = $*CURPAD;
    }
    $*CU = SAST::CompUnit.new(block => $*CURPAD,name => $*CU-name);
}

method statementlist($/) {
    make do if $<statement> {
        $<statement>.map(*.ast);
    } else {
        []
    }
}

method statement($/) {
    my $stmt = (.values[0].ast with $<statement>);
    make $stmt;
}


# Statement modifers like:
# say "foo:{.uc}" if $foo
# need a lexical scope on the LHS controlled by the if statement in
# order to make sure $_ in '{.uc}' is set to the if statement's topic.
# Since we only find this out after the LHS expression has been parsed we
# need to fix it up afterwards.
sub fixup-scopes($_, :$wrong!, :$right!) {
    when SAST::Block    { .outer = $right if .outer === $wrong }
    when SAST::Children { .&fixup-scopes(:$wrong,:$right)  for .children }
}

method EXPR-and-mod ($/) {
    my $expr = $<EXPR>.ast;

    my $CURPAD = $*CURPAD;
    my $loop;

    with $<statement-mod-loop> {
        $loop = .ast;
        $loop.ann<statement-mod> = True;
        $loop.block = SAST::Block.new(outer => $CURPAD);
    }

    with $<statement-mod-cond> {
        my $cond = .ast;
        $cond.ann<statement-mod> = True;
        if $loop {
            $cond.then = SAST::Block.new($expr,outer => $loop.block);
            fixup-scopes  $expr, wrong => $CURPAD, right => $cond.then;
            fixup-scopes  $cond, wrong => $CURPAD, right => $loop.block;
            $loop.block.push($cond);
            $expr = $loop;
        } else {
            $cond.then = SAST::Block.new($expr,outer => $CURPAD);
            fixup-scopes  $expr, wrong => $CURPAD, right => $cond.then;
            $expr = $cond;
        }
    } elsif $loop {
        fixup-scopes  $expr, wrong => $CURPAD, right => $loop.block;
        $loop.block.push($expr);
        $expr = $loop;
    }

    make $expr;
}

method pragma:sym<use>($/) {
    my $spec = $<EXPR>.ast;
    my $match = $/; # BUG? $/ is being reset inside CATCH

    my %use = ($<identifier> andthen id => .Str)
    || (repo-type => $<repo-type>.Str,
        id => $<angle-quote>.ast.val);
    my $CU;

    for @*repos -> $repo {
        ($CU = $repo.load(|%use,:$.debug)) && last;
        CATCH {
            SX::ModuleLoad.new(
                :$repo,
                exception => $_,
                |%use,
                :$match,
            ).throw;
        }
    }
    if $CU {
        my @exported := $CU.exported;
        for SymbolType::.values -> $symbol-type {
            for @exported[$symbol-type].?values {
                $*CURPAD.declare($_);
            }
        }
    } else {
        SX::ModuleNotFound.new(|%use,:@*repos).throw;
    }
    make SAST::Empty.new;
}


method statement-prefix:phaser ($/) {
    make SAST::PhaserBlock.new(block => $<blorst>.ast, stage => Spit-Phaser::{$<sym>.Str});
}

method statement-prefix:sym<quietly> ($/) {
    make SAST::Quietly.new(block => $<blorst>.ast);
}

method statement-prefix:sym<start> ($/) {
    make SAST::Start.new(block => $<blorst>.ast);
}

method statement-mod-cond:sym<if> ($/) {
    my $expr = $<EXPR>.ast;
    $expr = SAST::Neg.new($expr) if $<sym>.Str eq 'unless';
    make SAST::If.new(cond => $expr);
}

method statement-mod-loop:sym<for> ($/) {
    make SAST::For.new(list => $<list>.ast)
}

method statement-mod-loop:sym<while> ($/) {
    make SAST::While.new(cond => $<EXPR>.ast,until => $<sym> eq 'until');
}

method statement-control:sym<if> ($/) {
    my $expr =  $<EXPR>.ast;
    $expr = SAST::Neg.new($expr) if $<sym>.Str eq 'unless';
    my $topic-var = do with $<var-and-type>.ast {
        .dont-depend = True;
        $_;
    };
    my $if = SAST::If.new(
        cond => $expr,
        then => $<block>.ast,
        |(:$topic-var if $topic-var),
    );
    my SAST $prev-if = $if;

    for |$<elsif> {
        my $current-else = SAST::If.new(
            cond => .<EXPR>.ast,
            then => .<block>.ast,
        );
        $prev-if.else = $current-else;
        $prev-if = $current-else;
    }
    with $<else> {
        $prev-if.else = .ast;
    }
    make $if;
}

method statement-control:sym<loop> ($/) {
    with $<loop-spec><wrapped> {
        make SAST::Loop.new:
          init   => .<init>.ast,
          cond   => .<cond>.ast,
          incr   => .<incr>.ast,
          block  => $<block>.ast;
    } else {
        make SAST::Loop.new(block => $<block>.ast);
    }
}

method statement-control:sym<for> ($/) {
    my $iter-var = do with $<var-and-type> {
        my $var = .ast;
        $var.dont-depend = True;
        $var;
    };
    make SAST::For.new(
        list => $<list>.ast,
        block => $<block>.ast,
        |(:$iter-var if $iter-var),
    );
}

method statement-control:sym<while> ($/) {
    my $topic-var = do with $<var-and-type> {
        my $var = .ast;
        $var.dont-depend = True;
        $var;
    };
    make SAST::While.new(
        until => ($<sym>.Str eq 'until'),
        cond => $<EXPR>.ast,
        block => $<block>.ast,
        |(:$topic-var if $topic-var),
    );
}

method statement-control:sym<given> ($/) {
    make SAST::Given.new(
        block => $<block>.ast,
        given => $<EXPR>.ast,
    );
}

method statement-control:sym<when> ($/) {
    my ($if,$last,$this);
    for $/[0] {
        $this = SAST::If.new(
            cond => $_<EXPR>.ast,
            then => $_<blockish>.ast,
            :when,
        );
        $if //= $this;
        $last.else = $this if $last and $last ~~ SAST::If;
        $last = $this;
    }

    $<default> andthen $last.else = .ast;

    make $if;
}

method declare-new-type($/,$name,\MetaType) {
    my $type :=
      do if $!use-bootstrap-types and %bootstrapped-types{$name}
      -> $predeclared {
          $predeclared
      } else {
          MetaType.new_type(:$name);
      }
    my $CLASS := SAST::ClassDeclaration.new(class => $type);
    $type.^set-declaration($CLASS);
    $*CLASS = $*CURPAD.declare: $CLASS;
    $*CU.export: CLASS,$name,$CLASS;
    $CLASS;
}

sub set-primitive(Mu $type is raw) {
    $type.^add_parent(tStr) if $type.^primitive =:= Mu;
    $type
}

method declaration:sym<class> ($/){
    my $class =  $<new-class>.ast;
    set-primitive($class.class);
    $class.class.^compose;
    $class.block = $<blockoid>.ast;
    make $class;
}

method declare-class-params ($/) {
    my $type := $*CLASS.class;
    my @params := do given $type.HOW {
        when Spit::Metamodel::Parameterizable {
            $type.^placeholder-params
        }
        when Spit::Metamodel::Parameterized {
            $type.^derived-from.^placeholder-params;
        }
        default { () }
    };
    for @params -> $placeholder {
        $*CURPAD.declare: SAST::ClassDeclaration.new(class => $placeholder);
    }
}

method new-class ($/) {
    my $class;
    with $<params><wrapped> {
        $class = self.declare-new-type($/,$<type-name>.Str, Spit::Metamodel::Parameterizable);
        for $_<type-name>.map(*.Str).kv -> $i,$name {
            my $placeholder-type := Spit::Metamodel::Parameter.new_type(:$name);
            set-primitive($placeholder-type);
            $placeholder-type.^set-param-of($class.class,$i);
            $placeholder-type.^compose;
            $class.class.^placeholder-params.push($placeholder-type);
        }
    } else {
        $class = self.declare-new-type($/,$<type-name>.Str, Spit::Metamodel::Type);
    }
    make $class;
}

method declaration:sym<augment> ($/) {
    my $augmented-class := $<old-class>.ast;
    $augmented-class.block = $<blockoid>.ast;
    $augmented-class.class.^compose;
    make $augmented-class;
}

method old-class ($/) {
    my $class = $<type>.&_ast;
    my $decl = $*CLASS = SAST::ClassDeclaration.new(:$class);
    make $decl;
}

method declaration:sym<enum-class> ($/) {
    my $enum-class =  $<new-enum-class>.ast;
    unless $enum-class.class.^parents {
        $enum-class.class.^add_parent(tEnumClass);
    }
    $enum-class.class.^compose;
    $enum-class.block = $<block>.ast;
    $/.make: $enum-class;
}

method new-enum-class ($/) {
    make self.declare-new-type($/,$<type-name>.Str,Spit::Metamodel::EnumClass);
}

method trait:sym<is> ($/){
    if $<primitive> {
        $*CLASS.class.^set-primitive($*CLASS.class);
    } elsif $<native> {
        $*ROUTINE.is-native = True;
    } elsif $<export> {
        $*CU.export($*DECL);
    } elsif $<rw> {
        $*ROUTINE.rw  = True;
    } elsif $<required> {
        $*DECL ~~ SAST::Option or
          SX.new(message => 'You can only put ‘is required’ on options').throw;

        $*DECL.required = True;
    } elsif $<return-by-var> {
        $*ROUTINE.return-by-var = True;
    } elsif $<impure> {
        $*ROUTINE.impure = True;
    } elsif $<no-inline> {
        $*ROUTINE.no-inline = True;
    } elsif $<logged-as> {
        $*DECL.logged-as = $<logged-as>.ast;
    } else {
        $*CLASS.class.^add_parent($<type>.&_ast);
    }
}

method declaration:sym<sub> ($/) {
    make $*CURPAD.declare: $<routine-declaration>.ast;
}

method declaration:sym<method> ($/) {
    my $method := $<routine-declaration>.ast;
    $method.class-type = $*CLASS.class;
    make $*CLASS.class.^add-spit-method: $method;
}



method routine-declaration ($/) {

    given $*ROUTINE -> $r {
        $r.os-candidates =  $<on-switch>.ast || (tOS, $<cmd-blockoid>.ast);
        make $r;
    }
}

method new-routine($/) {
    my (:@pos,:%named) := $<param-def>.ast<paramlist>.ast;
    my $r = $*ROUTINE;
    $r.signature = SAST::Signature.new(:@pos,:%named);
    $r.return-type = .&_ast with $<return-type> || $<return-type-sigil>;
    make $r;
}

method make-routine ($/,$type,:$static) {
    my $name = $<name>.Str;
    $*ROUTINE = do given $type {
        when 'sub' { SAST::SubDeclare.new(:$name) }
        when 'method'  {
            SX.new(message => 'methdod declared outside of a class').throw unless $*CLASS;
            my $r = SAST::MethodDeclare.new(:$name);
            if $*CURPAD.lookup(CLASS,$name) -> $matching-class {
                $r.return-type = $matching-class.class;
            }
            unless $static {
                $r.invocant = $*CURPAD.declare: SAST::Invocant.new(
                    class-type => $*CLASS.class
                );
            }
            $r;
        }
    };
}

method on-switch ($/) {
    # XXX: BUG in rakudo. Value from seq disappears so assign to array first.
    my @tmp = $/<candidates>.ast[0].map({  $_<os>.ast, $_<cmd-blockish>.ast }).flat;
    make @tmp;
}

method declaration:var ($/) {
    my $var = $<var-and-type>.ast;
    $var.assign = $<statement>.ast;
    make $*CURPAD.declare: $var;
}

method return-type-sigil:sym<~>($/) { make tStr }
method return-type-sigil:sym<+>($/) { make tInt }
method return-type-sigil:sym<?>($/) { make tBool }
method return-type-sigil:sym<@>($/) { make tList }
method return-type-sigil:sym<^>($/) {
    $*CLASS or
      SX.new(message => 'Whatever-Invocant return type used outside of a class').throw;

    make $*CLASS.class.^whatever-invocant;
}

method return-type-sigil:sym<*>($/) {
    make tWhateverContext;
}

method paramlist ($/) {
    my @params = $<params>.map(*<param>.ast);

    my %paramlist := Map.new:
       (pos => @params.grep(SAST::PosParam)),
       (named => @params.grep(SAST::NamedParam).map({ .name => $_ }).Map);


    make %paramlist;
}

method param ($/) {
    make $*CURPAD.declare: do if $<pos> {
        SAST::PosParam.new(
            name => $<name>.Str,
            sigil => $<sigil>.Str,
            |(decl-type => .&_ast with $<type>),
            |(default => .ast with $<default>),
            optional => ?$<optional>,
            slurpy => ?$<slurpy>.Str
        )
    } else {
        SAST::NamedParam.new(
            name => $<name>.Str,
            sigil => $<sigil>.Str,
            |(decl-type => .&_ast with $<type>),
            |(default => .ast with $<default>),
            optional => $<optional>,
        )
    }
}

method EXPR($/) {
    my @infixes = $<infix> || ();
    my SAST:D @terms = $<termish>.map: -> $term {
        #CATCH {  }
        my $res := $term.ast;
        SX.new(message => 'internal error while compiling this node ' ~ $term.gist, match => $term).throw
           unless $res ~~ SAST:D;
        $res;
    };

    while @infixes {
        for ^@infixes -> $i {
            my $this = @infixes[$i];
            my $next = @infixes[$i+1];
            my ($precedence,$assoc) = $this.&derive-precedence(@terms[$i]);
            my $next-precedence = $next.&derive-precedence(@terms[$i+1])[0];
            my $cmp = $assoc == LEFT ?? &infix:«ge» !! &infix:«gt»;

            if $cmp($precedence,$next-precedence) {
                my $infix-sast = $this.ast;
                # Some infix might not be as simple as appending the terms to the
                # SAST node. So we allow it to return a callable which will be called
                # with the terms.
                if $infix-sast ~~ Callable {
                    $infix-sast = $infix-sast(|@terms.splice($i,2));
                    @terms.splice($i,0,$infix-sast);
                } else {
                    $infix-sast.append: @terms.splice($i,2,$infix-sast);
                }
                @infixes.splice($i,1);
                last;
            }
        }
    }
    make @terms[0];
}

method list ($/) {
    my $list = SAST::List.new;
    for $<EXPR> {
        $list.push(.ast);
    }
    make $list;
}
sub reduce-term(Match:D $term,@prefixes,@postfixes) {
    my $ret = $term.ast;
    for |@postfixes,|@prefixes.reverse {
        my $ast = .ast;
        if $ast ~~ Callable {
            $ret = $ast.($ret);
        } else {
            $ast.push($ret);
            $ret = $ast;
        }
    }
    $ret
}
method termish($/) {
    make reduce-term($<term>,$<prefix>,$<postfix>);
}

method term:true  ($/) { make SAST::BVal.new(val => True) }
method term:false ($/) { make SAST::BVal.new(val => False) }

method term:my ($/) {
    make $*CURPAD.declare: $<var-and-type>.ast;
}

method var-create($/,$decl-type) {
    my $ast-type = do given $decl-type {
        when 'constant'  { SAST::ConstantDecl }
        when 'my'        { SAST::VarDecl }
        when 'topic'     { SAST::MaybeReplace }
        when 'env'       { SAST::EnvDecl }
    };
    my $name = $<var><name>.Str;
    my $package;
    if $name.starts-with(':') {
        $ast-type = $ast-type but SAST::Option;
        $package = ($*CLASS andthen .class);
    }

    make $ast-type.new(
        :$name,
        sigil => $<var><sigil>.Str,
        |(decl-type => .&_ast with $<type>),
        match => $/,
        :$package,
    );
}

method term:quote ($/)   { make $<quote>.ast  }
method term:int ($/)   { make $<int>.ast    }
method int ($/) { make SAST::IVal.new: val => $/.Int }

method term:var-ref ($/) { make $<var-ref>.ast }

method var-ref ($/) {
    my $var = ($<var> // $<package-opt>);
    make $<accessor> ?? reduce-term($var, (), $<accessor>) !! $var.ast;
}

method var ($/)   {
    with $<special-var> {
        make .ast;
    }
    orwith $<option> {
        make SAST::OptionVal.new(sigil => $<sigil>.Str, name => .<angle-quote>.ast);
    }
    else {
        my $name = $<name>.Str;
        if $name eq '?PID' and $<sigil> eq '$' {
            make SAST::CurrentPID.new
        }
        elsif $name eq '?spit-version' {
            use Spit::Util :spit-version;
            make SAST::SVal.new(val => spit-version().Str);
        }
        else {
            make SAST::Var.new(
                name => $<name>.Str,
                sigil => $<sigil>.Str,
            );
        }
    }
}

method package-opt ($/) {
    make SAST::Var.new(
        name => $<opt-name>.Str,
        sigil => $<sigil>.Str,
        package => $<package-name>.Str,
    );
}

method term:circumfix ($/) {
    make $<circumfix>.ast
}
method circumfix:sym«< >» ($/) { make $<angle-quote>.ast }
method circumfix:sym<( )> ($/) {
    my @stmts = $<statementlist>.ast;
    make do if not @stmts {
        SAST::Empty.new;
    } elsif @stmts == 1 {
        @stmts[0];
    } else {
        SAST::Stmts.new(|@stmts)
    }
}
method circumfix:sym<{ }> ($/) {
    my $block = $<block>.ast;
    my @pairs;
    make do if # if it's empty, has one pair or a list of pairs then it's a json object
      ( $block.children == 0) or
      $block.one-stmt andthen (
        $_ ~~ SAST::Pair and @pairs = $_ or
        (
            $_ ~~ SAST::List and
            not .children.first(* !~~ SAST::Pair) and
            @pairs = .children
        )
      )
    {
        SAST::SubCall.new(
            name => 'j-object',
            match => $/,
            pos => flat @pairs.map: {
                SAST::Blessed.new(
                    .key,
                    class-type => tStr,
                    match => .key.match
                ),
                .value
            }
        );
    }
    else {  $block }
}
method circumfix:sym<[ ]> ($/) {
    make SAST::SubCall.new(
        name => 'j-array',
        match => $/,
        pos => $<list>.ast.children,
    )
}

method special-var:sym<?> ($/) { make SAST::LastExitStatus.new }

method term:name ($/) {
    my $name = $<name>.Str;
    make do if $<is-type> {
        my @params = $<type-params>.ast || Empty;
        my $class-type := lookup-type($name, :@params, match => $<name>);
        do with $<object> {
            do if $_<angle-quote>
               andthen (my $list = .ast) ~~ SAST::List
               and $class-type !~~ tList
            {
                for $list.children {
                    $_ = SAST::Blessed.new(
                        :$class-type,
                        :@params,
                        match => .match,
                        $_,
                    );
                }
                $list;
            } else {
                my $definite = $list || $_<EXPR>.ast;
                SAST::Blessed.new(
                    :$class-type,
                    :@params,
                    $definite,
                )
            }
        } else {
            SAST::Type.new(
                :$class-type,
                :@params,
            )
        }
    } else {
        my (:@pos,:%named) := $<call-args><args>.ast || Empty;
        SAST::SubCall.new(:$name,:@pos,:%named);
    }
}

method term:sast ($/) {
    my (:@pos,:%named) := $<args>.ast;
    make ::('SAST::' ~ $<identifier>.Str).new(|@pos,|%named);
}

method term:cmd ($/) {
    make $<cmd>.ast;
}

method term:cmd-capture ($/) {
    make SAST::List.new(|$<cmd>.ast.nodes);
}

method term:topic-call ($/) {
    my $call = $<method-call>.ast;
    $call.push: SAST::Var.new(name => '_',sigil => '$');
    make $call;
}

method term:topic-cast ($/) {
    make SAST::Cast.new(to => $<type>.&_ast,SAST::Var.new(name => '_',sigil => '$'));
}

method term:statement-prefix ($/) { make $<statement-prefix>.ast }

method term:sym<on> ($/) {
    make SAST::OnBlock.new: os-candidates => $<on-switch>.ast;
}

method term:pair ($/) { make SAST::Pair.new(|$<pair>.ast) }

method pair ($/) { make $<pair>.ast }

method colon-pair ($/) {
    my ($key,$value,$match);
    with $<var-ref> {
        $key = .ast.bare-name;
        $match = $_;
        $value = .ast;
    } else {
        $key = $<key>.Str;
        $match = $<key>;
        if $<neg> {
            $value = SAST::BVal.new(val => False);
        }
        elsif $<value> {
            $value = $<value>.ast;
        }
        else {
            $value = SAST::BVal.new(val => True);
        }
    }
    $key = SAST::SVal.new(val => $key.Str, :$match);
    make ($key,$value);
}

method fatarrow-pair ($/) {
    make (SAST::SVal.new(val => $<key>.Str, match => $<key>), $<value>.ast);
}

method eq-infix:sym<&&> ($/)  { make SAST::Junction.new }
method eq-infix:sym<||> ($/)  { make SAST::Junction.new(:dis) }
method eq-infix:sym<and> ($/) { make SAST::Junction.new }
method eq-infix:sym<or> ($/)  { make SAST::Junction.new(:dis) }
method eq-infix:sym<~> ($/)   { make SAST::Concat.new() }
method eq-infix:intexpr ($/)  { make SAST::IntExpr.new(sym => $<sym>.Str) }

method infix:eq-infix ($/) { make $<sym>.ast }
method infix:sym<=> ($/) {
    make -> $var,$val {
        if $var ~~ SAST::Assignable && $var.assign-type {
            $var.assign = $val;
            $<eq-infix> andthen $var.assign-mod = .ast;
        } else {
            SX::Assignment-Readonly.new.throw;
        }
        $var;
    }
}
method infix:sym<.=> ($/) {
    make -> $var,$_ {
        unless $var ~~ SAST::Assignable && $var.assign-type {
            SX::Assignment-Readonly.new.throw
        }
        when SAST::Call {
            $var.assign = .make-new(
                SAST::MethodCall,
                :name(.name),
                :named(.named),
                :pos(.pos),
                $var.gen-reference(match => $var.match),
            );
            $var;
        }
        when SAST::Cmd {
            proceed if .pipe-in;
            .pipe-in = $var.gen-reference(match => $var.match);
            $var.assign = $_;
            $var;
        }
        default {
            SX::Invalid.new(invalid => 'RHS for ‘.=’').throw;
        }
    }
}
method infix:sym<,>  ($/) {
    make -> $lhs,$rhs? {
        if $lhs ~~ SAST::List && $rhs !~~ SAST::List {
            $lhs.push($rhs) if $rhs;
            $lhs;
        } else {
            SAST::List.new($lhs, $rhs // Empty);
        }
    }
}

method infix:sym<~~> ($/) { make SAST::ACCEPTS.new }

method infix:comparison ($/) { make SAST::Cmp.new(sym => $<sym>.Str)  }

method infix:sym<..> ($/) {
    make SAST::Range.new(
        :$<exclude-start>,
        :$<exclude-end>,
    );
}

method infix:sym<?? !!> ($/) {
    my $on-true = $<EXPR>.ast;
    make -> $cond,$on-false {
        SAST::Ternary.new(
            :$cond,
            :$on-false,
            :$on-true
        );
    }
}

method infix:sym«=>» ($/) { make SAST::Pair.new }

method method-call ($/) {
    my (:@pos,:%named) := $<args>.ast;
    my $name = $<name>.Str;
    make do given $name {
        when 'WHAT' { SAST::WHAT.new }
        when 'WHY'  { SAST::WHY.new }
        when 'PRIMITIVE' { SAST::PRIMITIVE.new }
        when 'NAME' { SAST::NAME.new }
        default {
            SAST::MethodCall.new(
                :$name,
                :@pos,
                :%named,
            );
        }
    }
}

method postfix:method-call ($/) { make $<method-call>.ast }

method args ($/,|) {
    make {
        pos => $<pos>.map(*.ast),
        named => $<named>.map({ my ($k,$v) := .ast; ($k.val, $v) }).flat.Hash,
    }
}

method postfix:cmd-call ($/) {
    my $first = $<cmd>.ast;
    my $last = $first;
    $last = $last.pipe-in while $last.pipe-in;
    make -> $called-on {
        $last.pipe-in = $called-on;
        $first;
    };
}

method postfix:sym<++> ($/)  { make SAST::Increment.new }
method postfix:sym<--> ($/)  { make SAST::Increment.new(:decrement) }
method postfix:sym<[ ]> ($/) { make $<index-accessor>.ast }
method index-accessor($/) {
    make SAST::Elem.new(index => $<EXPR>.ast, index-type => tInt);
}
method postfix:sym<{ }>($/) { make $<curly-key-accessor>.ast }
method curly-key-accessor($/) { make SAST::Elem.new(index => $<EXPR>.ast, index-type => tStr) }

method postfix:sym«< >»($/) { make $<angle-key-accessor>.ast }
method angle-key-accessor($/) {
    make SAST::Elem.new(index => $<angle-quote>.ast, index-type => tStr)
}

method postfix:sym<⟶> ($/) { make SAST::Cast.new(to => $<type>.&_ast) }
method prefix:sym<~> ($/) { make SAST::Coerce.new(to => tStr) }
method prefix:sym<+> ($/) { make SAST::Coerce.new(to => tInt) }
method prefix:sym<-> ($/) { make SAST::Negative.new() }
method prefix:sym<?> ($/) { make SAST::Coerce.new(to => tBool)}
method prefix:sym<!> ($/) { make SAST::Neg.new() }
method prefix:sym<++> ($/) { make SAST::Increment.new(:pre) }
method prefix:sym<--> ($/) { make SAST::Increment.new(:pre,:decrement) }
method prefix:sym<^>  ($/) { make SAST::Range.new(SAST::IVal.new(val => 0),:exclude-end) }
method prefix:i-sigil ($/) {
    make do given $<sigil>.Str {
        when '$'|'@' { SAST::Itemize.new(sigil => $_) }
        default { die "invalid itemizing sigil: $_" }
    }
}
method prefix:sym<@>  ($/) { make SAST::Itemize(sigil => $<sym>.Str) }

method pblock($/) {
    if $<lambda> {
        make $<blockoid>.ast;
    } else {
        make $<block>.ast;
    }
}

method blockoid($/) {
    my $pad = $*CURPAD;
    $pad.append($<statementlist>.ast);
    make $pad;
}

method cmd-blockoid($/) {
    make do with $<cmd> {
        my $pad = $*CURPAD;
        $pad.append(.ast);
        $pad;
    } else {
        $<blockoid>.ast;
    }
}

method blockish($/) {
    make $<blockoid>.ast;
}

method cmd-blockish($/) {
    make $<cmd-blockoid>.ast;
}

method block($/)    {
    make $<blockish>.ast
}

method cmd-block($/)    {
    make $<cmd-blockish>.ast;
}

method blorst($/) {
    make do with $<block> {
        .ast
    } else {
        given $<statement>.ast {
            when SAST::Stmts { $_ }
            default { SAST::Stmts.new($_) }
        }
    }
}

method type ($/) {
    make do with $<parameter-index> {
        my \type = lookup-type($<type-name>.Str, match => $/);
        if type.HOW ~~ Spit::Metamodel::Parameter {
            type.^param-at($_<index>.Str.Int);
        } else {
            SX.new(message => "Can't index a type unless it's a parameter type").throw;
        }
    } else {
        lookup-type(
            $/<type-name>.Str,
            params => ($<type-params>.ast // Empty),
            match => $/,
        );
    }
}

method type-params ($/) {
    make ($<params> andthen .<wrapped><type>.map(*.&_ast));
}

method os   ($/) { make $*CURPAD.lookup(CLASS,$/.Str,match => $/).class }

method cmd ($/) { make $<cmd-pipe-chain>.ast }

method cmd-pipe-chain ($/) {
    my $cmd;
    for $<cmd-body>.map(*.ast) -> $next {
        $next.pipe-in = $cmd with $cmd;
        $cmd = $next;
    }
    make $cmd;
}

method cmd-body ($/) {
    my (SAST:D @pos,SAST:D %set-env,SAST:D @write,SAST:D @append,SAST:D @in);
    for $<cmd-arg> {
        with $_<cmd-term> {
            @pos.push: .ast;
        }
        orwith $_<bare> {
            @pos.push: SAST::SVal.new(val => .Str);
        }
        orwith $_<parens> {
            @pos.push: .ast
        }
        orwith $_<pair>.ast {
            %set-env{.key.compile-time} = .value;
        }
        orwith $_<redirection> {
            my (@add-write,@add-append,@add-in) := .ast;
            @write.append(@add-write);
            @append.append(@add-append);
            @in.append(@add-in);
        }
    }

    make SAST::Cmd.new(|@pos,:%set-env,:@write,:@append,:@in);
}

method cmd-term ($/) {
    make reduce-term($/[0].values[0],$<i-sigil>,$<postfix>);
}


method redirection($/) {
    my &make-fd =  { SAST::Blessed.new(class-name => 'FD',SAST::IVal.new(val => $_),match => $/) }
    my $src = $<src>;
    my @src-fd = (
        ($src<all> andthen (make-fd(1),make-fd(2)))
        or $src<fd> andthen .ast
        or ($src<err> && make-fd(2))
        or ($<in> ?? make-fd(0) !! make-fd(1) )
    );

    my $dst = $<dst>;

    my @log-levels = do with $dst<log> {
        #  >info/warn results in <log-level>, <err-log-level>
        # *>info results in <log-level>, <log-level>
        if .<err-log-level> {
            @src-fd.push(make-fd(2));
            .<log-level>, (.<err-log-level> ?? .<err-log-level> !! .<log-level>);
        } else {
            .<log-level>, .<log-level>;
        }
    };

    my $gen-dst =
       $dst<null>   ?? { $*SETTING.lookup(SCALAR,':NULL').gen-reference(match => $dst<null>)  }
       !! $dst<cap> ?? { $*SETTING.lookup(SCALAR,'?CAP').gen-reference(match => $dst<cap>) }
       !! $dst<err> ?? { $*SETTING.lookup(SCALAR,':ERR').gen-reference(match => $dst<err>) }
                       # only clone on the second invocation if any
       !! $dst<fd>  ?? { $++ ?? $dst<fd>.ast !! $dst<fd>.ast.deep-clone }
       !! {
           my $log   = $dst<log>;

           my $level = @log-levels[$++].ast; # get the next log level
           my $path = $log<empty-path> ??
             $*SETTING.lookup(SCALAR, ':log-default-path').gen-reference(match => $log<empty-path>)
             !! (
               $log<symbol-path> andthen SAST::SVal.new(val => "$_ ")
               or
               $log<literal-path> andthen SAST::SVal.new(val => .Str)
               or
               $log<path> andthen ($++ ?? .ast !! .ast.deep-clone);
             );
           SAST::OutputToLog.new(:$path, :$level);
       }

    my (@write,@append,@in);
    for @src-fd -> $src-fd {
        if $<write> {
            @write.append: $src-fd,$gen-dst();
        } elsif $<append> {
            @append.append: $src-fd,$gen-dst();
        } else {
            @in.append: $src-fd,$gen-dst();
        }
    }
    make (@write,@append,@in);
}

method log-level($/) {
    make SAST::IVal.new: val => do given $/.Str {
        when 'fatal' { 5 }
        when 'error' { 4 }
        when 'warn'  { 3 }
        when 'info'  { 2 }
        when 'debug' { 1 }
    };
}

sub make-quote($/) { make $<str>.ast andthen .match = $/ }
method quote:double-quote       ($/) { make-quote($/) }
method quote:curly-double-quote ($/) { make-quote($/) }
method quote:single-quote       ($/) { make-quote($/) }
method quote:curly-single-quote ($/) { make-quote($/) }
method quote:half-bracket-quote    ($/) { make-quote($/) }
method quote:sym<qq>            ($/) { make-quote($/) }
method quote:sym<q>             ($/) { make-quote($/) }
method quote:sym<Q>             ($/) { make-quote($/) }
method balanced-quote           ($/) { make-quote($/) }
method quote:regex              ($/) { make-quote($/) }


method angle-quote ($/) {
    my $val = $<str>.Str;
    my SAST::CompileTimeVal @parts = $val.split(" ").grep(?*).map: {
        do if try .Int ~~ Int {
            SAST::IVal.new(val => .Int);
        } else {
            SAST::SVal.new(val => $_);
        }
    };
    make do if @parts > 1 {
        SAST::List.new(|@parts);
    } elsif @parts == 1 {
        @parts[0];
    } else {
        SAST::Empty.new;
    }
}

method quote:sym<eval> ($/) {
    my $src = $<balanced-quote>.ast;
    my %opts = $<args>.ast.<named> || Empty;
    for |($<args> andthen .ast<pos>) {
        when SAST::Pair {
            with .key.compile-time -> $key {
                %opts{$key} = .value;
            } else {
                SX.new(message => 'eval key must be known at compile time',
                       match => .key.match).throw;
            }
        }
        default {
            SX.new(message => ‘eval doesn't take positional arguments’, match => .match).throw;
        }
    }
    make SAST::Eval.new(:%opts, compunit => $*CU);
}

method new-eval-pad($/) {
    my $new = SAST::EvalBlock.new;
    $new.outer = $_ with CALLERS::<$*CURPAD>;
    $*CURPAD = $new;
    $*CU = SAST::CompUnit.new(name => "eval_{$++}", block => $new);
}

method wrap ($/) {
    with $<wrapped><R> {
        make .ast;
    } else {
        make $<wrapped>;
    }
}
