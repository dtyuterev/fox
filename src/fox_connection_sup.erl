-module(fox_connection_sup).
-behaviour(supervisor).

-export([start_link/2, init/1, create_channel/1, subscribe/4, unsubscribe/2, stop/1]).

-include("otp_types.hrl").
-include("fox.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").


%% Module API

-spec start_link(#amqp_params_network{}, integer()) -> {ok, pid()} | {error, term()}.
start_link(Params, PoolSize) ->
    supervisor:start_link(?MODULE, {Params, PoolSize}).


-spec init(gs_args()) -> sup_init_reply().
init({Params, PoolSize}) ->
    Spec = fun(Id) ->
                   {{fox_connection_worker, Id},
                    {fox_connection_worker, start_link, [Params]},
                    transient, 2000, worker,
                    [fox_connection_worker]}
           end,
    Childs = [Spec(Id) || Id <- lists:seq(1, PoolSize)],
    {ok, {{one_for_one, 10, 60}, Childs}}.


-spec create_channel(pid()) -> {ok, pid()} | {error, term()}.
create_channel(SupPid) ->
    fox_connection_worker:create_channel(get_less_busy_worker(SupPid)).


-spec subscribe(pid(), list(), module(), list()) -> {ok, reference()} | {error, term()}.
subscribe(SupPid, Queues, ConsumerModule, ConsumerModuleArgs) ->
    Worker = get_less_busy_worker(SupPid),
    fox_connection_worker:subscribe(Worker, Queues, ConsumerModule, ConsumerModuleArgs).


-spec unsubscribe(pid(), pid()) -> ok | {error, term()}.
unsubscribe(SupPid, ChannelPid) ->
    Res = lists:map(fun({_, ChildPid, _, _}) ->
                            fox_connection_worker:unsubscribe(ChildPid, ChannelPid)
                    end,
                    supervisor:which_children(SupPid)),
    case lists:member(ok, Res) of
        true -> ok;
        false -> {error, connection_not_found}
    end.


-spec stop(pid()) -> ok.
stop(SupPid) ->
    lists:foreach(fun({_, ChildPid, _, _}) ->
                          fox_connection_worker:stop(ChildPid)
                  end,
                  supervisor:which_children(SupPid)),
    ok.


%% Inner functions

-spec get_less_busy_worker(pid()) -> pid().
get_less_busy_worker(SupPid) ->
    element(2, hd(lists:sort(lists:map(
                               fun({_, ChildPid, _, _}) ->
                                       case fox_connection_worker:get_info(ChildPid) of
                                           {num_channels, Num} -> {Num, ChildPid};
                                           no_connection -> {infinity, ChildPid}
                                       end
                               end,
                               supervisor:which_children(SupPid))))).
