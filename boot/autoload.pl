/*  $Id$

    Copyright (c) 1990 Jan Wielemaker. All rights reserved.
    jan@swi.psy.uva.nl

    Purpose: Automatic library loading
*/

:- module($autoload,
	[ $find_library/5
	, $in_library/2
	, $define_predicate/1
	, $update_library_index/0
	, make_library_index/1
	, make_library_index/2
	, autoload/0
	, autoload/1
	]).

:- dynamic
	library_index/3.			% Head x Module x Path
:- volatile
	library_index/3.

%	$find_library(+Module, +Name, +Arity, -LoadModule, -Library)
%
%	Locate a predicate in the library.  Name and arity are the name
%	and arity of the predicate searched for.  `Module' is the
%	preferred target module.  The return values are the full path names
%	of the library and module declared in that file.

$find_library(Module, Name, Arity, LoadModule, Library) :-
	load_library_index,
	functor(Head, Name, Arity),
	(   library_index(Head, Module, Library),
	    LoadModule = Module
	;   library_index(Head, LoadModule, Library)
	), !.

%	$in_library(?Name, ?Arity)
%	Is true if Name/Arity is in the autoload libraries.

$in_library(Name, Arity) :-
	load_library_index,
	library_index(Head, _, _),
	functor(Head, Name, Arity).

%	$define_predicate(+Head)
%	Make sure pred can be called.  First test if the predicate is
%	defined.  If not, invoke the autoloader.

:- module_transparent
	$define_predicate/1.

$define_predicate(Head) :-
	$defined_predicate(Head), !.
$define_predicate(Term) :-
	$strip_module(Term, Module, Head),
	functor(Head, Name, Arity),
	feature(autoload, true),
	$find_library(Module, Name, Arity, LoadModule, Library),
	flag($autoloading, Old, Old+1),
	(   Module == LoadModule
	->  ignore(ensure_loaded(Library))
	;   ignore(Module:use_module(Library, [Name/Arity]))
	),
	flag($autoloading, _, Old),
	$define_predicate(Term).


		/********************************
		*          UPDATE INDEX		*
		********************************/

$update_library_index :-
	absolute_file_name(library('INDEX'),
			   [ file_errors(fail),
			     solutions(all),
			     access(write),
			     access(read),
			     file_type(prolog)
			   ], IndexFile),
	file_directory_name(IndexFile, Dir),
	update_library_index(Dir),
	fail.
$update_library_index.

update_library_index(Dir) :-
	user:prolog_file_type(Ext, prolog),
	concat_atom([Dir, '/INDEX.', Ext], IndexFile),
	access_file(IndexFile, write),
	make_library_index(Dir).

clear_library_index :-
	retractall(library_index(_, _, _)).

		/********************************
		*           LOAD INDEX		*
		********************************/

load_library_index :-
	library_index(_, _, _), !.		% loaded
load_library_index :-
	absolute_file_name(library('INDEX'),
			   [ file_type(prolog),
			     access(read),
			     solutions(all),
			     file_errors(fail)
			   ], Index),
	    file_directory_name(Index, Dir),
	    read_index(Index, Dir),
	fail.
load_library_index.
	
read_index(Index, Dir) :-
	seeing(Old), see(Index),
	repeat,
	    read(Term),
	    (   Term == end_of_file
	    ->  !
	    ;   assert_index(Term, Dir),
	        fail
	    ),
	seen, see(Old).

assert_index(index(Name, Arity, Module, File), Dir) :- !,
	functor(Head, Name, Arity),
	concat_atom([Dir, '/', File], Path),
	assertz(library_index(Head, Module, Path)).
assert_index(Term, Dir) :-
	$warning('Illegal term in INDEX file of directory ~w: ~w',
		 [Dir, Term]).
	

		/********************************
		*       CREATE INDEX.pl		*
		********************************/

make_library_index(Dir) :-
	findall(Pattern, source_file_pattern(Pattern), PatternList),
	make_library_index(Dir, PatternList).
	
make_library_index(Dir, Patterns) :-
	once(user:prolog_file_type(PlExt, prolog)),
	file_name_extension('INDEX', PlExt, Index),
	concat_atom([Dir, '/', Index], AbsIndex),
	access_file(AbsIndex, write), !,
	absolute_file_name('', OldDir),
	chdir(Dir),
	expand_index_file_patterns(Patterns, Files),
	(   library_index_out_of_date(Index, Files)
	->  format('Making library index for ~w ... ', Dir), flush,
	    do_make_library_index(Index, Files),
	    format('ok~n')
	;   true
	),
	chdir(OldDir).
make_library_index(Dir, _) :-
	$warning('make_library_index/1: Cannot write ~w', [Dir]).

source_file_pattern(Pattern) :-
	user:prolog_file_type(PlExt, prolog),
	concat('*.', PlExt, Pattern).

expand_index_file_patterns(Patterns, Files) :-
	maplist(expand_file_name, Patterns, NestedFiles),
	flatten(NestedFiles, Files).

library_index_out_of_date(Index, _Files) :-
	\+ exists_file(Index), !.
library_index_out_of_date(Index, Files) :-
	time_file(Index, IndexTime),
	(   time_file('.', DotTime),
	    DotTime @> IndexTime
	;   member(File, Files),
	    time_file(File, FileTime),
	    FileTime @> IndexTime
	), !.


do_make_library_index(Index, Files) :-
	open(Index, write, Fd),
	index_header(Fd),
	checklist(index_file(Fd), Files),
	close(Fd).

index_file(Fd, File) :-
	open(File, read, In),
	read(In, Term),
	close(In),
	Term = (:- module(Module, Public)), !,
	file_name_extension(Base, _, File),
	forall( member(Name/Arity, Public),
		format(Fd, 'index((~k), ~k, ~k, ~k).~n',
		       [Name, Arity, Module, Base])).
index_file(_, _).

index_header(Fd):-
	format(Fd, '/*  $Id', []),
	format(Fd, '$~n~n', []),
	format(Fd, '    Creator: make/0~n~n', []),
	format(Fd, '    Purpose: Provide index for autoload~n', []),
	format(Fd, '*/~n~n', []).

		 /*******************************
		 *	   DO AUTOLOAD		*
		 *******************************/

%	autoload([options ...]) 
%
%	Force all necessary autoloading to be done now.

autoload :-
	autoload([]).

autoload(Options) :-
	option(Options, verbose/true, Verbose),
	$style_check(Old, Old), 
	style_check(+dollar), 
	feature(autoload, OldAutoLoad),
	feature(verbose_autoload, OldVerbose),
	set_feature(autoload, false),
	findall(Pred, needs_autoloading(Pred), Preds),
	set_feature(autoload, OldAutoLoad),
	$style_check(_, Old),
	(   Preds == []
	->  true
	;   set_feature(autoload, true),
	    set_feature(verbose_autoload, Verbose),
	    checklist($define_predicate, Preds),
	    set_feature(autoload, OldAutoLoad),
	    set_feature(verbose_autoload, OldVerbose),
	    autoload(Verbose)		% recurse for possible new
					% unresolved links
	).
	
needs_autoloading(Module:Head) :-
	predicate_property(Module:Head, undefined), 
	\+ predicate_property(Module:Head, imported_from(_)), 
	functor(Head, Functor, Arity), 
	$in_library(Functor, Arity).

option(Options, Name/Default, Value) :-
	(   memberchk(Name = Value, Options)
	->  true
	;   Value = Default
	).

