%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2011 Trifork
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------

-module(rebar_prv_shell).
-author("Kresten Krab Thorup <krab@trifork.com>").

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include("rebar.hrl").

-define(PROVIDER, shell).
-define(DEPS, [compile]).

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(
            State,
            providers:create([
                {name, ?PROVIDER},
                {module, ?MODULE},
                {bare, true},
                {deps, ?DEPS},
                {example, "rebar3 shell"},
                {short_desc, "Run shell with project apps and deps in path."},
                {desc, info()},
                {opts, [{config, undefined, "config", string,
                         "Path to the config file to use. Defaults to "
                         "{shell, [{config, File}]} and then the relx "
                         "sys.config file if not specified."},
                        {name, undefined, "name", atom,
                         "Gives a long name to the node."},
                        {sname, undefined, "sname", atom,
                         "Gives a short name to the node."},
                        {script_file, undefined, "script", string,
                         "Path to an escript file to run before "
                         "starting the project apps. Defaults to "
                         "rebar.config {shell, [{script_file, File}]} "
                         "if not specified."},
                        {apps, undefined, "apps", string,
                         "A list of apps to boot before starting the "
                         "shell. (E.g. --apps app1,app2,app3) Defaults "
                         "to rebar.config {shell, [{apps, Apps}]} or "
                         "relx apps if not specified."}]}
            ])
    ),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(Config) ->
    shell(Config),
    {ok, Config}.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%% NOTE:
%% this is an attempt to replicate `erl -pa ./ebin -pa deps/*/ebin`. it is
%% mostly successful but does stop and then restart the user io system to get
%% around issues with rebar being an escript and starting in `noshell` mode.
%% it also lacks the ctrl-c interrupt handler that `erl` features. ctrl-c will
%% immediately kill the script. ctrl-g, however, works fine

shell(State) ->
    setup_name(State),
    setup_paths(State),
    setup_shell(),
    maybe_run_script(State),
    %% apps must be started after the change in shell because otherwise
    %% their application masters never gets the new group leader (held in
    %% their internal state)
    maybe_boot_apps(State),
    simulate_proc_lib(),
    true = register(rebar_agent, self()),
    {ok, GenState} = rebar_agent:init(State),
    gen_server:enter_loop(rebar_agent, [], GenState, {local, rebar_agent}, hibernate).

info() ->
    "Start a shell with project and deps preloaded similar to~n'erl -pa ebin -pa deps/*/ebin'.~n".

setup_shell() ->
    %% scan all processes for any with references to the old user and save them to
    %% update later
    OldUser = whereis(user),
    %% terminate the current user
    ok = supervisor:terminate_child(kernel_sup, user),
    %% start a new shell (this also starts a new user under the correct group)
    _ = user_drv:start(),
    %% wait until user_drv and user have been registered (max 3 seconds)
    ok = wait_until_user_started(3000),
    NewUser = whereis(user),
    %% set any process that had a reference to the old user's group leader to the
    %% new user process. Catch the race condition when the Pid exited after the
    %% liveness check.
    _ = [catch erlang:group_leader(NewUser, Pid)
         || Pid <- erlang:processes(),
            proplists:get_value(group_leader, erlang:process_info(Pid)) == OldUser,
            is_process_alive(Pid)],
    %% Application masters have the same problem, but they hold the old group
    %% leader in their state and hold on to it. Re-point the processes whose
    %% leaders are application masters. This can mess up a few things around
    %% shutdown time, but is nicer than the current lock-up.
    OldMasters = [Pid
         || Pid <- erlang:processes(),
            Pid < NewUser, % only change old masters
            {_,Dict} <- [erlang:process_info(Pid, dictionary)],
            {application_master,init,4} == proplists:get_value('$initial_call', Dict)],
    _ = [catch erlang:group_leader(NewUser, Pid)
         || Pid <- erlang:processes(),
            lists:member(proplists:get_value(group_leader, erlang:process_info(Pid)),
                         OldMasters)],
    try
        %% enable error_logger's tty output
        error_logger:swap_handler(tty),
        %% disable the simple error_logger (which may have been added multiple
        %% times). removes at most the error_logger added by init and the
        %% error_logger added by the tty handler
        remove_error_handler(3)
    catch
        E:R -> % may fail with custom loggers
            ?DEBUG("Logger changes failed for ~p:~p (~p)", [E,R,erlang:get_stacktrace()]),
            hope_for_best
    end.

setup_paths(State) ->
    %% Add deps to path
    code:add_pathsa(rebar_state:code_paths(State, all_deps)),
    %% add project app test paths
    ok = add_test_paths(State).

maybe_run_script(State) ->
    case first_value([fun find_script_option/1,
                      fun find_script_rebar/1], State) of
        no_value ->
            ?DEBUG("No script_file specified.", []),
            ok;
        "none" ->
            ?DEBUG("Shell script execution skipped (--script none).", []),
            ok;
        RelFile ->
            File = filename:absname(RelFile),
            try run_script_file(File)
            catch
                C:E ->
                    ?ABORT("Couldn't run shell escript ~p - ~p:~p~nStack: ~p",
                           [File, C, E, erlang:get_stacktrace()])
            end
    end.

-spec find_script_option(rebar_state:t()) -> no_value | list().
find_script_option(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    debug_get_value(script_file, Opts, no_value,
                    "Found script file from command line option.").

-spec find_script_rebar(rebar_state:t()) -> no_value | list().
find_script_rebar(State) ->
    Config = rebar_state:get(State, shell, []),
    %% Either a string, or undefined
    debug_get_value(script_file, Config, no_value,
                    "Found script file from rebar config file.").

run_script_file(File) ->
    ?DEBUG("Extracting escript from ~p", [File]),
    {ok, Script} = escript:extract(File, [compile_source]),
    Beam = proplists:get_value(source, Script),
    Mod = proplists:get_value(module, beam_lib:info(Beam)),
    ?DEBUG("Compiled escript as ~p", [Mod]),
    FakeFile = "/fake_path/" ++ atom_to_list(Mod),
    {module, Mod} = code:load_binary(Mod, FakeFile, Beam),
    ?DEBUG("Evaling ~p:main([]).", [Mod]),
    Result = Mod:main([]),
    ?DEBUG("Result: ~p", [Result]),
    Result.

maybe_boot_apps(State) ->
    case find_apps_to_boot(State) of
        undefined ->
            %% try to read in sys.config file
            ok = rebar_app_config:reread_config(State, config, shell);
        Apps ->
            %% load apps, then check config, then boot them.
            load_apps(Apps),
            ok = rebar_app_config:reread_config(State, config, shell),
            boot_apps(Apps)
    end.

simulate_proc_lib() ->
    FakeParent = spawn_link(fun() -> timer:sleep(infinity) end),
    put('$ancestors', [FakeParent]),
    put('$initial_call', {rebar_agent, init, 1}).

setup_name(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    case {proplists:get_value(name, Opts), proplists:get_value(sname, Opts)} of
        {undefined, undefined} ->
            ok;
        {Name, undefined} ->
            check_epmd(net_kernel:start([Name, longnames]));
        {undefined, SName} ->
            check_epmd(net_kernel:start([SName, shortnames]));
        {_, _} ->
            ?ABORT("Cannot have both short and long node names defined", [])
    end.

check_epmd({error,{{shutdown, {_,net_kernel,{'EXIT',nodistribution}}},_}}) ->
    ?ERROR("Erlang Distribution failed, falling back to nonode@nohost. "
           "Verify that epmd is running and try again.",[]);
check_epmd(_) ->
    ok.

find_apps_to_boot(State) ->
    %% Try the shell_apps option
    case first_value([fun find_apps_option/1,
                      fun find_apps_rebar/1,
                      fun find_apps_relx/1], State) of
        no_value ->
            undefined;
        Apps ->
            Apps
    end.

-spec find_apps_option(rebar_state:t()) -> no_value | [atom()].
find_apps_option(State) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    case debug_get_value(apps, Opts, no_value,
                         "Found shell apps from command line option.") of
        no_value -> no_value;
        AppsStr ->
            [ list_to_atom(AppStr)
              || AppStr <- string:tokens(AppsStr, " ,:") ]
    end.

-spec find_apps_rebar(rebar_state:t()) -> no_value | list().
find_apps_rebar(State) ->
    ShellOpts = rebar_state:get(State, shell, []),
    debug_get_value(apps, ShellOpts, no_value,
                    "Found shell opts from command line option.").

-spec find_apps_relx(rebar_state:t()) -> no_value | list().
find_apps_relx(State) ->
    case lists:keyfind(release, 1, rebar_state:get(State, relx, [])) of
        {_, _, Apps} ->
            ?DEBUG("Found shell apps from relx.", []),
            Apps;
        false ->
            no_value
    end.

load_apps(Apps) ->
    [case application:load(App) of
        ok ->
             {ok, Ks} = application:get_all_key(App),
             load_apps(proplists:get_value(applications, Ks));
        _ ->
            error % will be caught when starting the app
     end || App <- normalize_load_apps(Apps),
            not lists:keymember(App, 1, application:loaded_applications())],
    ok.

boot_apps(Apps) ->
    ?WARN("The rebar3 shell is a development tool; to deploy "
            "applications in production, consider using releases "
            "(http://www.rebar3.org/v3.0/docs/releases)", []),
    Normalized = normalize_boot_apps(Apps),
    Res = [application:ensure_all_started(App) || App <- Normalized],
    _ = [?INFO("Booted ~p", [App])
            || {ok, Booted} <- Res,
            App <- Booted],
    _ = [?ERROR("Failed to boot ~p for reason ~p", [App, Reason])
            || {error, {App, Reason}} <- Res],
    ok.

normalize_load_apps([]) -> [];
normalize_load_apps([{App, _} | T]) -> [App | normalize_load_apps(T)];
normalize_load_apps([{App, _Vsn, load} | T]) -> [App | normalize_load_apps(T)];
normalize_load_apps([App | T]) when is_atom(App) -> [App | normalize_load_apps(T)].

normalize_boot_apps([]) -> [];
normalize_boot_apps([{_App, load} | T]) -> normalize_boot_apps(T);
normalize_boot_apps([{_App, _Vsn, load} | T]) -> normalize_boot_apps(T);
normalize_boot_apps([{App, _Vsn} | T]) -> [App | normalize_boot_apps(T)];
normalize_boot_apps([App | T]) when is_atom(App) -> [App | normalize_boot_apps(T)].


remove_error_handler(0) ->
    ?WARN("Unable to remove simple error_logger handler", []);
remove_error_handler(N) ->
    case gen_event:delete_handler(error_logger, error_logger, []) of
        {error, module_not_found} -> ok;
        {error_logger, _} -> remove_error_handler(N-1)
    end.

%% Timeout is a period to wait before giving up
wait_until_user_started(0) ->
    ?ABORT("Timeout exceeded waiting for `user` to register itself", []),
    erlang:error(timeout);
wait_until_user_started(Timeout) ->
    case whereis(user) of
        %% if user is not yet registered wait a tenth of a second and try again
        undefined -> timer:sleep(100), wait_until_user_started(Timeout - 100);
        _ -> ok
    end.

add_test_paths(State) ->
    _ = [begin
            AppDir = rebar_app_info:out_dir(App),
            %% ignore errors resulting from non-existent directories
            _ = code:add_path(filename:join([AppDir, "test"]))
         end || App <- rebar_state:project_apps(State)],
    _ = code:add_path(filename:join([rebar_dir:base_dir(State), "test"])),
    ok.

-spec first_value([Fun], State) -> no_value | Value when
      Value :: any(),
      State :: rebar_state:t(),
      Fun :: fun ((State) -> no_value | Value).
first_value([], _) -> no_value;
first_value([Fun | Rest], State) -> 
    case Fun(State) of
        no_value ->
            first_value(Rest, State);
        Value ->
            Value
    end.

debug_get_value(Key, List, Default, Description) ->
    case proplists:get_value(Key, List, Default) of
        Default -> Default;
        Value ->
            ?DEBUG(Description, []),
            Value
    end.
