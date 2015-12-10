-module(rebar_app_config).

-export([reread_config/3]).

-include("rebar.hrl").


reread_config(State, Opt, OptGroup) ->
    case find_config(State, Opt, OptGroup) of
        no_config ->
            ok;
        ConfigList ->
            _ = [application:set_env(Application, Key, Val)
                  || {Application, Items} <- ConfigList,
                     {Key, Val} <- Items],
            ok
    end.

% First try the --config flag, then try the relx sys_config
-spec find_config(rebar_state:t(), atom(), atom()) -> [tuple()] | no_config.
find_config(State, Opt, OptGroup) ->
    case first_value([fun find_config_option/3,
                      fun find_config_rebar/3,
                      fun find_config_relx/3], State, Opt, OptGroup) of
        no_value ->
            no_config;
        Filename when is_list(Filename) ->
            consult_config(State, Filename)
    end.

-spec first_value([Fun], State, Opt, OptGroup) -> no_value | Value when
      Value :: any(),
      State :: rebar_state:t(),
      Opt :: atom(),
      OptGroup :: atom(),
      Fun :: fun ((State) -> no_value | Value).
first_value([], _, _, _) -> no_value;
first_value([Fun | Rest], State, Opt, OptGroup) ->
    case Fun(State, Opt, OptGroup) of
        no_value ->
            first_value(Rest, State, Opt, OptGroup);
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

-spec find_config_option(rebar_state:t(), atom(), atom()) -> Filename::list() | no_value.
find_config_option(State, Opt, _OptGroup) ->
    {Opts, _} = rebar_state:command_parsed_args(State),
    debug_get_value(Opt, Opts, no_value,
                    "Found config from command line option.").

-spec find_config_rebar(rebar_state:t(), atom(), atom()) -> [tuple()] | no_value.
find_config_rebar(State, Opt, OptGroup) ->
    debug_get_value(Opt, rebar_state:get(State, OptGroup, []), no_value,
                    "Found config from rebar config file.").

-spec find_config_relx(rebar_state:t(), atom(), atom()) -> [tuple()] | no_value.
find_config_relx(State, _Opt, _OptGroup) ->
    debug_get_value(sys_config, rebar_state:get(State, relx, []), no_value,
                    "Found config from relx.").

-spec consult_config(rebar_state:t(), string()) -> [tuple()].
consult_config(State, Filename) ->
    Fullpath = filename:join(rebar_dir:root_dir(State), Filename),
    ?DEBUG("Loading configuration from ~p", [Fullpath]),
    case rebar_file_utils:try_consult(Fullpath) of
        [T] -> T;
        [] -> []
    end.
