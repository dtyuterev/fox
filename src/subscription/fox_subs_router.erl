-module(fox_subs_router).
-behavior(gen_server).

-export([start_link/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("otp_types.hrl").
-include("fox.hrl").

-record(state, {
    subscription :: #subscription{}, % TODO do I need it? I need only channel
    workers :: map()
}).


%%% module API

-spec start_link(#subscription{}) -> gs_start_link_reply().
start_link(Sub) ->
    gen_server:start_link(?MODULE, Sub, []).


-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).


%%% gen_server API

-spec init(gs_args()) -> gs_init_reply().
init(#subscription{
    channel_pid = Channel,
    queues = Queues,
    consumer_module = ConsumerModule,
    consumer_args = ConsumerArgs} = Sub
) ->
    io:format("~n#~nrouter init ~p~n", [Sub]),
    % TODO need supervisor to start worker
    {ok, Worker} = fox_subs_worker:start_link(Channel, ConsumerModule, ConsumerArgs),

    Workers = lists:foldl(
        fun(Queue, W) ->
            BConsume =
                case Queue of
                    #'basic.consume'{} = B -> B;
                    QueueName when is_binary(QueueName) -> #'basic.consume'{queue = QueueName}
                end,
            #'basic.consume_ok'{consumer_tag = Tag} = amqp_channel:subscribe(Channel, BConsume, self()),
            W#{Tag => Worker}
        end, #{}, Queues),
    io:format("~n#~nWorkers:~p~n", [Workers]),
    {ok, #state{subscription = Sub, workers = Workers}}.


-spec handle_call(gs_request(), gs_from(), gs_reply()) -> gs_call_reply().
handle_call(stop, _From, #state{subscription = Sub, workers = Workers} = State) ->
    #subscription{channel_pid = Channel} = Sub,
    lists:foreach(
        fun(Tag) ->
            fox_utils:channel_call(Channel, #'basic.cancel'{consumer_tag = Tag})
        end,
        maps:keys(Workers)),

    %% TODO stop all workers
    %% ConsumerModule:terminate(ChannelPid, CState)
    {stop, normal, ok, State};

handle_call(Any, _From, State) ->
    error_logger:error_msg("unknown call ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_cast(gs_request(), gs_state()) -> gs_cast_reply().
handle_cast(Any, State) ->
    error_logger:error_msg("unknown cast ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_info(gs_request(), gs_state()) -> gs_info_reply().
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{consumer_tag = Tag}, _} = Msg, State) ->
    route(Tag, Msg, State),
    {noreply, State};

handle_info(#'basic.cancel'{consumer_tag = Tag} = Msg, State) ->
    route(Tag, Msg, State),
    {noreply, State};

handle_info(Request, State) ->
    error_logger:error_msg("unknown info ~p in ~p ~n", [Request, ?MODULE]),
    {noreply, State}.


-spec terminate(terminate_reason(), gs_state()) -> ok.
terminate(_Reason, _State) ->
    ok.


-spec code_change(term(), term(), term()) -> gs_code_change_reply().
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.


%%% inner functions

route(Tag, Msg, #state{workers = Workers}) ->
    case maps:find(Tag, Workers) of
        {ok, Worker} -> Worker ! Msg;
        error -> error_logger:error_msg("~p got unknown consumer_tag ~p", [?MODULE, Tag])
    end.