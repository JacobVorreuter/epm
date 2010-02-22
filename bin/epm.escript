#!/usr/bin/env escript

-include_lib("xmerl/include/xmerl.hrl").

%% -----------------------------------------------------------------------------
%% main function
%% -----------------------------------------------------------------------------
main(Args) ->
	case (catch main1(Args)) of
		{'EXIT', ErrorMsg} when is_list(ErrorMsg) ->
			io:format("- ~s~n", [ErrorMsg]);
		{'EXIT', Other} ->
			io:format("~p~n", [Other]);
		_ ->
			ok
	end.
	
main1(Args) ->
	%ensure_erlang_vsn(),
	ensure_git(),
	
	inets:start(),
	
	%% consult global .epm config file in home directory
	Home = 
		case init:get_argument(home) of
			{ok, [[H]]} -> [H];
			_ -> []
		end,
    case file:path_consult(["."] ++ Home ++ [code:root_dir()], ".epm") of
		{ok, [GlobalConfig], _} ->
			execute(GlobalConfig, Args);
		{error, enoent} ->
			execute([], Args);
		{error, Reason} ->
			io:format("- failed to read epm global config: ~p~n", [Reason])
	end.
	
%% -----------------------------------------------------------------------------
%% execute function
%% -----------------------------------------------------------------------------
execute(GlobalConfig, ["install" | Args]) ->
    {Projects, Flags} = collect_args(install, Args),
	put(verbose, lists:member(verbose, Flags)),
	[case package_info(ProjectName) of
        {error, not_found} ->
			install_package(GlobalConfig, User, ProjectName, CommandLineTags);
		{error, Reason} ->
			io:format("- there was a problem with the installed version of ~s: ~p~n", [ProjectName, Reason]),
			install_package(GlobalConfig, User, ProjectName, CommandLineTags);
        {ok, Version} ->
			io:format("+ skipping ~s: already installed (~p)~n", [ProjectName, Version])
    end || {{User, ProjectName}, CommandLineTags} <- Projects];

execute(GlobalConfig, ["remove" | Args]) ->
	{Projects, Flags} = collect_args(remove, Args),
	put(verbose, lists:member(verbose, Flags)),
    [case code:lib_dir(ProjectName) of
        {error, _} -> io:format("+ skipping ~s: not installed~n", [ProjectName]);
        Path -> remove_package(GlobalConfig, ProjectName, Path)
	 end || {{_User, ProjectName}, _CommandLineTags} <- Projects];

execute(_GlobalConfig, ["info" | Args]) ->
	{Projects, Flags} = collect_args(info, Args),
	put(verbose, lists:member(verbose, Flags)),
    [case code:lib_dir(ProjectName) of
        {error, _} -> io:format("+ ~s: not installed~n", [ProjectName]);
        Path -> io:format("+ ~s installed (~s)~n", [ProjectName, Path])
	 end || {{_User, ProjectName}, _CommandLineTags} <- Projects];
	
execute(_, _) ->
    io:format("epm v0.0.1, 2010 Nick Gerakines, Jacob Vorreuter~n"),
    io:format("Usage: epm command arguments~n"),
    io:format("    install [<user>/]<project> [--tag <tag>] [--branch <branch>] [--sha <sha>] [--force] [--verbose]~n"),
    io:format("    remove <project> [--verbose]~n"),
    io:format("    info <project> [--verbose]~n"),
	%io:format("    test [<user>/]<project> [--tag <tag>] [--branch <branch>] [--sha <sha>] [--verbose]~n"),
    ok.

%% -----------------------------------------------------------------------------
%% internal functions
%% -----------------------------------------------------------------------------
collect_args(Target, Args) -> collect_args(Target, Args, [], []).

collect_args(_, [], Acc1, Acc2) -> {lists:reverse(Acc1), lists:reverse(Acc2)};
	
collect_args(Target, [Arg | Rest], Acc1, Acc2) ->
	case parse_tag(Target, Arg) of
		undefined -> %% if not a tag then must be a project name
			{ProjectName, User} = split_package(Arg), %% split into user and project
			collect_args(Target, Rest, [{{User, ProjectName}, []} | Acc1], Acc2);
		{Tag, true} -> %% tag with trailing value
			[Value | Rest1] = Rest, %% pop trailing value from front of remaining args
			[{Project, Props} | Acc0] = Acc1, %% this tag applies to the last project on the stack
			collect_args(Target, Rest1, [{Project, Props ++ [{Tag, Value}]} | Acc0], Acc2);
		{Tag, false} ->	 %% tag with no trailing value
			[{Project, Props} | Acc0] = Acc1, %% this tag applies to the last project on the stack
			collect_args(Target, Rest, [{Project, Props ++ [Tag]} | Acc0], Acc2);
		Other ->
			collect_args(Target, Rest, Acc1, [Other|Acc2])
	end.

split_package(Raw) -> split_package(Raw, []).
split_package([], Package) -> {Package, none};
split_package([47 | Package], User) -> {Package, User};
split_package([A | Tail], User) -> split_package(Tail, User ++ [A]).

package_info(Package) when is_list(Package) ->
    package_info(list_to_atom(Package));
package_info(Package) ->
    case code:lib_dir(Package) of
        {error, bad_name} -> {error, not_found};
        Path ->
            case file:consult(Path ++ "/ebin/" ++ atom_to_list(Package) ++ ".app") of
                {ok, [{application, _, AppContents}]} -> {ok, proplists:get_value(vsn, AppContents)};
                _ -> {error, no_app_file}
            end
    end.

%% @spec parse_tag(Target, Arg) -> {Tag, HasValue} | undefined
%%		 Target = atom()
%%		 Arg = string()
%%		 Tag = atom()
%%		 HasValue = bool()
parse_tag(install, "--tag") -> {tag, true};
parse_tag(install, "--branch") -> {branch, true};
parse_tag(install, "--sha") -> {sha, true};
parse_tag(install, "--force") -> {force, false};
parse_tag(_, "--verbose") -> verbose;
parse_tag(_, _) -> undefined.

install_package(GlobalConfig, User, ProjectName, CommandLineTags) ->
	io:format("+ install package ~s~n", [ProjectName]),
	
	%% switch to build home dir
	set_cwd_build_home(GlobalConfig),
	
	%% clone repo
	LocalProjectDir = checkout_package(GlobalConfig, User, ProjectName),
	
	%% switch to project dir
	set_cwd_build_home(GlobalConfig),
	set_cwd(LocalProjectDir),
	
	%% ensure correct branch, tag or sha is checked out
	checkout_correct_version(CommandLineTags),
	
	%% install dependencies from .epm file
	install_dependencies(GlobalConfig, ProjectName),
	
	% io:format("~s~n", [string:copies("+", 80)]),
	% 	io:format("++~s++~n", [string:centre("installing " ++ ProjectName, 76, $ )]),
	% 	io:format("~s~n", [string:copies("+", 80)]),
	
	%% switch to project dir
	set_cwd_build_home(GlobalConfig),
	set_cwd(LocalProjectDir),
	
	%% build/install project
	build_project(GlobalConfig, ProjectName, CommandLineTags),
	
	%% switch to build home dir and delete cloned project
	set_cwd_build_home(GlobalConfig),
	del_dir(LocalProjectDir),
	
	ok.
	
remove_package(_GlobalConfig, ProjectName, Path) ->
	io:format("+ removing package ~s (~s)~n", [ProjectName, Path]),
	RemoveCmd = "rm -rf " ++ Path,
	print_cmd_output("~s~n", [RemoveCmd]),
	do_cmd(RemoveCmd, fail).

checkout_package(GlobalConfig, User, ProjectName) ->
	Paths = proplists:get_value(git_paths, GlobalConfig, ["git://github.com/<user>/<project>.git"]),
	{LocalProjectDir, GitUrl} = search_sources_for_project(Paths, User, ProjectName),
	del_dir(LocalProjectDir), %% delete dir if it already exists
	io:format("+ checking out ~s~n", [GitUrl]),
	case do_cmd("git clone " ++ GitUrl ++ " " ++ LocalProjectDir) of
		{0, "Initialized empty Git repository" ++ _ = Result} ->
			print_cmd_output("~s~n", [Result]),
			LocalProjectDir;
		{_, Other} ->
			print_cmd_output("~s~n", [Other]),
			exit(lists:flatten(io_lib:format("failed to checkout ~s", [GitUrl])))
	end.

search_sources_for_project(["git://github.com" ++ _ | _Tail], none, ProjectName) ->	
	Repos = 
		case repos_search(ProjectName) of
			#xmlElement{name=repositories, content=Repos0} -> Repos0;
			_ -> []
		end,
	Filtered = lists:filter(
		fun (#xmlElement{name=repository}=Repo) ->
				case {xmerl_xpath:string("/repository/name/text()", Repo),
					  xmerl_xpath:string("/repository/language/text()", Repo),
					  xmerl_xpath:string("/repository/type/text()", Repo)} of
					{[Name], [Lang], [Type]} ->
						Name#xmlText.value == ProjectName andalso
						Lang#xmlText.value == "Erlang" andalso
						Type#xmlText.value == "repo";
					_ ->
						false
				end;
			(_) -> false
		end, Repos),		
	if
		Filtered == [] ->
			exit(lists:flatten(io_lib:format("failed to locate remote repo for ~s", [ProjectName])));
		true -> ok
	end,
	Repo = 
		case lists:filter(
			fun(R) ->
				xmerl_xpath:string("/repository/username/text()", R) == [#xmlText{value="epm"}]
			end, Filtered) of
			[] -> hd(Filtered);
			[R1] -> R1				
		end,
	[Username] = xmerl_xpath:string("/repository/username/text()", Repo),
	[RepoName] = xmerl_xpath:string("/repository/name/text()", Repo),
	{Username#xmlText.value ++ "-" ++ RepoName#xmlText.value, "git://github.com/" ++ Username#xmlText.value ++ "/" ++ RepoName#xmlText.value ++ ".git"};
	
search_sources_for_project(["git://github.com" ++ _ | _Tail], User, ProjectName) ->
	case repos_info(User, ProjectName) of
		#xmlElement{name=repository}=Repo ->
			[Username] = xmerl_xpath:string("/repository/owner/text()", Repo),
			[RepoName] = xmerl_xpath:string("/repository/name/text()", Repo),
			{Username#xmlText.value ++ "-" ++ RepoName#xmlText.value, "git://github.com/" ++ Username#xmlText.value ++ "/" ++ RepoName#xmlText.value ++ ".git"};
		_ -> 
			exit(lists:flatten(io_lib:format("failed to locate remote repo for ~s", [ProjectName])))
	end;

search_sources_for_project(_, _, _) ->
	exit(lists:flatten(io_lib:format("currently github is the only supported remote repository"))).
	
set_cwd_build_home(GlobalConfig) ->	
	set_cwd(proplists:get_value(build_path, GlobalConfig, ".")).
	
set_cwd(Dir) ->
	case file:set_cwd(Dir) of
		ok -> 
			ok;
		{error, _} ->
			exit(lists:flatten(io_lib:format("failed to change working directory: ~s", [Dir])))
	end.

checkout_correct_version([{tag, Tag}|_]) ->
	case do_cmd("git checkout -b \"" ++ Tag ++ "\" \"" ++ Tag ++ "\"") of
		{0, "Switched to a new branch" ++ _} -> 
			ok;
		{_, Other} ->
			exit(lists:flatten(io_lib:format("failed to switch to tag ~s: ~p", [Tag, Other])))
	end;
	
checkout_correct_version([{branch, Branch}|_]) ->
	case do_cmd("git checkout -b \"" ++ Branch ++ "\"") of
		{0, "Switched to a new branch" ++ _} -> 
			ok;
		{_, Other} ->
			exit(lists:flatten(io_lib:format("failed to switch to branch ~s: ~p", [Branch, Other])))
	end;
	
checkout_correct_version([{sha, Sha}|_]) ->
	case do_cmd("git checkout -b \"" ++ Sha ++ "\"") of
		{0, "Switched to a new branch" ++ _} -> 
			ok;
		{_, Other} ->
			exit(lists:flatten(io_lib:format("failed to switch to sha ~s: ~p", [Sha, Other])))
	end;
		
checkout_correct_version([_|Tail]) ->	
	checkout_correct_version(Tail);
	
checkout_correct_version(_) -> ok.
	
install_dependencies(GlobalConfig, ProjectName) ->
	Config = read_project_epm_config(ProjectName),
	[begin
		{ProjectName1, User} = split_package(Project),
		case package_info(ProjectName1) of
	        {error, not_found} ->
				install_package(GlobalConfig, User, ProjectName1, CommandLineTags);
			{error, Reason} ->
				io:format("- there was a problem with the installed version of ~s: ~p~n", [ProjectName1, Reason]),
				install_package(GlobalConfig, User, ProjectName1, CommandLineTags);
	        {ok, Version} ->
				io:format("+ skipping dependency ~s: already installed (~p)~n", [ProjectName1, Version])
	    end
	 end || {Project, CommandLineTags} <- proplists:get_value(deps, Config, [])].
	
read_project_epm_config(ProjectName) ->
	case file:consult(ProjectName ++ ".epm") of
		{ok, [Config]} ->
			Config;
		{error, Reason} ->
			io:format("- failed to read ~s.epm config: ~p - using default values~n", [ProjectName, Reason]),
			[]
	end.
	
build_project(GlobalConfig, ProjectName, _CommandLineTags) ->
	Config = 
	    case file:consult(ProjectName ++ ".epm") of
    		{ok, [Config0]} -> Config0;
    		_ -> []
    	end,
	prebuild(ProjectName, Config),
	build(ProjectName, Config),
	%test(Config), %% TODO: add back in test step
	install(ProjectName, Config, proplists:get_value(install_path, GlobalConfig)).

prebuild(ProjectName, Config) ->
    case proplists:get_value(prebuild_command, Config) of
		undefined -> ok;
		PrebuildCmd -> 
			io:format("+ running ~s prebuild command~n", [ProjectName]),
			print_cmd_output("~s~n", [PrebuildCmd]),
			do_cmd(PrebuildCmd, fail)
	end.
	
build(ProjectName, Config) ->
    BuildCmd = proplists:get_value(build_command, Config, "make"),
	io:format("+ running ~s build command~n", [ProjectName]),
	print_cmd_output("~s~n", [BuildCmd]),
	do_cmd(BuildCmd, fail).
    
% test(Config) ->
%     TestCmd = proplists:get_value(test_command, Config, "make test"),
% 	io:format("+ test_command: ~s~n", [TestCmd]),
% 	{TestExitCode, TestOutput} = do_cmd(TestCmd),
% 	io:format("~s~n", [TestOutput]),
% 	TestExitCode.

install(ProjectName, Config, undefined) ->
	install(ProjectName, Config, code:lib_dir());

install(ProjectName, Config, LibDir) ->
	case proplists:get_value(install_command, Config) of
		undefined ->
			case file:consult("ebin/" ++ ProjectName ++ ".app") of
				{ok,[{application,_,Props}]} ->
					Vsn = proplists:get_value(vsn, Props, "0.0"),
					Dir = LibDir ++ "/" ++ ProjectName ++ "-" ++ Vsn,
					InstallCmd = "mkdir -p " ++ Dir ++ "; cp -R ./* " ++ Dir,
					io:format("+ running ~s install command~n", [ProjectName]),
					print_cmd_output("~s~n", [InstallCmd]),
					do_cmd(InstallCmd, fail),
					code:add_pathz(Dir);
				_ ->
					exit(lists:flatten(io_lib:format("failed to read ebin/~s.app", [ProjectName])))
			end;
		InstallCmd ->
			io:format("+ running ~s install command~n", [ProjectName]),
			print_cmd_output("~s~n", [InstallCmd]),
			do_cmd(InstallCmd, fail)
	end.
		
del_dir(Dir) ->
	case file:list_dir(Dir) of
		{ok, Files} ->
			[begin
				case file:delete(Dir ++ "/" ++ Filename) of
					ok -> ok;
					{error, eperm} ->
						case file:del_dir(Dir ++ "/" ++ Filename) of
							ok -> ok;
							{error, eexist} ->
								del_dir(Dir ++ "/" ++ Filename)
						end
				end
			end || Filename <- Files],
			file:del_dir(Dir);
		_ ->
			ok
	end.
	
do_cmd(Cmd, fail) ->
	case do_cmd(Cmd) of
		{0, ""} ->
			ok;
		{0, Output} ->
			print_cmd_output("~s~n", [Output]);
		{_, Output} ->
			exit(Output)
	end.
	
do_cmd(Cmd) ->
    Results = string:tokens(os:cmd(Cmd ++ "; echo $?"), "\n"),
    [ExitCode|Other] = lists:reverse(Results),
    {list_to_integer(ExitCode), string:join(lists:reverse(Other), "\n")}.
    
print_cmd_output(Format, Args) ->
	case get(verbose) of
		undefined -> print_cmd_output(Format, Args, false);
		Verbose -> print_cmd_output(Format, Args, Verbose)
	end.
	
print_cmd_output(_, _, false) -> ok; %% do not print verbose output
print_cmd_output(Format, Args, true) ->
	Str = lists:flatten(io_lib:format("    " ++ Format, Args)),
	Output = re:replace(Str, "\n", "\n    ", [global, {return, list}]),
	io:format(string:substr(Output, 1, length(Output)-4), []).
	
% ensure_erlang_vsn() ->
% 	%% greater than erts-5.7.4
% 	[Erts|_] = lists:reverse(string:tokens(code:lib_dir(erts), "/")),
% 	[_, Vsn] = string:tokens(Erts, "-"),
% 	Valid = 
% 		case [list_to_integer(X) || X <- string:tokens(Vsn, ".")] of
% 			[A,_,_] when A > 5 -> true;
% 			[5,B,_] when B > 7 -> true;
% 			[5,7,C] when C >= 4 -> true;
% 			_ -> false
% 		end,
% 	case Valid of
% 		true -> ok;
% 		false -> exit("epm requires Erlang version R13B03 or greater")
% 	end.
    	
ensure_git() ->
	case os:find_executable("git") of
		false -> exit("failed to locate git executable");
		_ -> ok
	end.	

repos_search(ProjectName) ->
	request_git_url("http://github.com/api/v2/xml/repos/search/" ++ ProjectName).
	
repos_info(User, ProjectName) ->
	request_git_url("http://github.com/api/v2/xml/repos/show/" ++ User ++ "/" ++ ProjectName).
	
request_git_url(Url) ->
    {ok, {{_, _RespCode, _}, _Headers, Body}} = 
		http:request(get, {Url, [{"User-Agent", "GitHubby/0.1"}, {"Host", "github.com"}]}, [{timeout, 6000}], []),
	{XmlElement, _} = xmerl_scan:string(Body),
	XmlElement.