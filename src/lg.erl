%% Copyright (c) 2017-Present Pivotal Software, Inc.  All rights reserved.
%%
%% This package, Looking Glass, is double-licensed under the Mozilla
%% Public License 1.1 ("MPL") and the Apache License version 2
%% ("ASL"). For the MPL, please see LICENSE-MPL-RabbitMQ. For the ASL,
%% please see LICENSE-APACHE2.
%%
%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND,
%% either express or implied. See the LICENSE file for specific language governing
%% rights and limitations of this software.
%%
%% If you have any questions regarding licensing, please contact us at
%% info@rabbitmq.com.

-module(lg).

-export([trace/1]).
-export([trace/2]).
-export([trace/3]).
-export([trace/4]).
-export([stop/0]).
-export([stop/1]).

-type pattern() :: module() | {app, atom()} | {callback, module(), atom()}.
-type scope() :: {scope, [
    pid() | port() | all | processes | ports |
    existing | existing_processes | existing_ports |
    new | new_processes | new_ports]}.

-type input() :: [pattern() | scope()].
-export_type([input/0]).

%% The trace functions input is not as strict for user convenience.
-type user_input() :: pattern() | input().

-type opts() :: #{
    mode => trace | profile,
    pool_id => any(),
    pool_size => pos_integer(),
    send => boolean(),
    running => boolean()
}.

-spec trace(user_input()) -> ok.
trace(Input) ->
    trace(Input, lg_raw_console_tracer).

-spec trace(user_input(), module()) -> ok.
trace(Input, TracerMod) ->
    trace(Input, TracerMod, undefined, #{}).

-spec trace(user_input(), module(), any()) -> ok.
trace(Input, TracerMod, TracerOpts) ->
    trace(Input, TracerMod, TracerOpts, #{}).

-spec trace(user_input(), module(), any(), opts()) -> ok.
trace(Input, TracerMod, TracerOpts, Opts) when is_list(Input) ->
    do_trace(Input, TracerMod, TracerOpts, Opts);
trace(Input, TracerMod, TracerOpts, Opts) ->
    trace([Input], TracerMod, TracerOpts, Opts).

do_trace(Input0, TracerMod, TracerOpts, Opts) ->
    %% @todo Remove eventually?
    _ = application:ensure_all_started(looking_glass),
    %% Start the pool of tracer processes.
    PoolID = maps:get(pool_id, Opts, default),
    PoolSize = maps:get(pool_size, Opts, erlang:system_info(schedulers)),
    true = PoolSize > 0,
    {ok, PoolPid} = supervisor:start_child(looking_glass_sup, #{
        id => PoolID,
        start => {lg_tracer_pool, start_link, [PoolSize, TracerMod, TracerOpts]},
        restart => temporary,
        type => supervisor
    }),
    Tracers = lg_tracer_pool:tracers(PoolPid),
    TracersMap = maps:from_list(lists:zip(lists:seq(0, length(Tracers) - 1), Tracers)),
    Mode = maps:get(mode, Opts, trace),
    Input1 = flatten(Input0, []),
    Input2 = ensure_pattern(Input1),
    Input = ensure_scope(Input2),
    trace_input(Input, #{mode => Mode, tracers => TracersMap}, Opts),
    ok.

flatten([], Acc) ->
    lists:flatten(Acc);
flatten([{callback, Mod, Fun}|Tail], Acc) when is_atom(Mod), is_atom(Fun) ->
    Input = flatten(Mod:Fun(), []),
    flatten(Tail, [Input|Acc]);
flatten([{app, App}|Tail], Acc) when is_atom(App) ->
    _ = application:load(App),
    {ok, Mods} = application:get_key(App, modules),
    flatten(Tail, [Mods|Acc]);
flatten([Input|Tail], Acc) ->
    flatten(Tail, [Input|Acc]).

ensure_pattern(Input) ->
    case [S || S={scope, _} <- Input] of
        Input -> ['_'|Input];
        _ -> Input
    end.

ensure_scope(Input) ->
    case [S || S={scope, _} <- Input] of
        [] -> [{scope, [processes]}|Input];
        _ -> Input
    end.

trace_input([], _, _) ->
    ok;
trace_input([{scope, Scope}|Tail], TracerState, Opts) ->
    %% We currently enable the following trace flags:
    %% - call: function calls
    %% - procs: process exit events; plus others we ignore
    %% - running: process being scheduled in/out
    %% - timestamp: events include the current timestamp
    %% - arity: function calls only include the arity, not arguments
    %% - return_to: return from functions
    %% - set_on_spawn: propagate trace flags to any children processes
    %%
    %% @todo It might be useful to count the number of sends
    %% or receives a function does.
    ExtraFlags = [running || maps:get(running, Opts, false)]
        ++ [send || maps:get(send, Opts, false)],
    _ = [erlang:trace(PidPortSpec, true, [
            call, procs, timestamp, arity, return_to, set_on_spawn,
            {tracer, lg_tracer, TracerState}
            |ExtraFlags
        ])
    || PidPortSpec <- Scope],
    trace_input(Tail, TracerState, Opts);
trace_input([Mod|Tail], TracerState, Opts) when is_atom(Mod) ->
    MatchSpec = case Opts of
        #{process_dump := true} -> [{'_', [], [{message, {process_dump}}]}];
        _ -> true
    end,
    %% The module must be loaded before we attempt to trace it.
    _ = code:ensure_loaded(Mod),
    _ = erlang:trace_pattern({Mod, '_', '_'}, MatchSpec, [local]),
    trace_input(Tail, TracerState, Opts).

stop() ->
    stop(default).

%% @todo Confirm that we don't need to stop tracing,
%% that just terminating the tracers is enough. The
%% NIF does cancel traces when tracers go away, but
%% better make sure.
stop(PoolID) ->
    supervisor:terminate_child(looking_glass_sup, PoolID).
