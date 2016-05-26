%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------


-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/1, stop/1, videocall/3, videocall_answer/2, echo/3]).
-export([list_rooms/1, create_room/2, destroy_room/2]).
-export([publish/4, unpublish/1, listen/4, listen_answer/2, listen_switch/3]).
-export([get_all/0, janus_event/4]).
-export([init/1, terminate/2, code_change/3, handle_call/3,
         handle_cast/2, handle_info/2]).

-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA Janus Session ~s (~s) "++Txt, 
               [State#state.id, State#state.status | Args])).

-include("nkmedia.hrl").


-define(OP_TIMEOUT, 50).
-define(RING_TIMEOUT, 50).
-define(CALL_TIMEOUT, 4*60*60).
-define(KEEPALIVE, 20).

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().

-type room() :: integer().

-type room_user_id() :: integer().

-type opts() ::
    #{
        bitrate => integer(),
        record => boolean(),
        filename => binary(),

        % For room creation:
        audiocodec => opus | isac32 | isac16 | pcmu | pcma,
        videocodec => vp8 | vp9 | h264,
        description => binary(),
        bitrate => integer(),
        publishers => integer(),
        record => boolean(),
        rec_dir => binary(),

        % For listeners
        audio => boolean(),
        video => boolean(),
        data => boolean()

    }.

-type status() ::
    wait | videocall | echo | publish | listen.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new session
-spec start(nkmedia_janus:id()) ->
    {ok, id(), pid()}.

start(JanusId) ->
    Id = nklib_util:uuid_4122(),
    {ok, Pid} = gen_server:start(?MODULE, {Id, JanusId, self()}, []),
    {ok, Id, Pid}.


%% @doc Stops a session
-spec stop(id()|pid()) ->
    ok.

stop(Id) ->
    do_cast(Id, stop).


%% @doc Starts a videocall inside the session.
%% The SDP offer for the remote party is returned.
-spec videocall(id()|pid(), nkmedia:offer(), opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

videocall(Id, Offer, Opts) ->
    do_call(Id, {videocall, Offer, Opts}).


%% @doc Answers a videocall from the remote party.
%% The SDP answer for the calling party is returned.
-spec videocall_answer(id()|pid(), nkmedia:answer()) ->
    {ok, nkmedia:answer()} | {error, term()}.

videocall_answer(Id, Answer) ->
    do_call(Id, {videocall_answer, Answer}).


%% @doc Starts a echo inside the session.
%% The SDP is returned.
-spec echo(id()|pid(), nkmedia:offer(), opts()) ->
    {ok, nkmedia:answer()} | {error, term()}.

echo(Id, Offer, Opts) ->
    do_call(Id, {echo, Offer, Opts}).



%% @doc List all videorooms
-spec list_rooms(id()|pid()) ->
    {ok, list()} | {error, term()}.

list_rooms(Id) ->
    do_call(Id, list_rooms).


%% @doc Creates a new videoroom
-spec create_room(id()|pid(), opts()) ->
    {ok, room()} | {error, term()}.

create_room(Id, Opts) ->
    do_call(Id, {create_room, Opts}).


%% @doc Destroys a videoroom
-spec destroy_room(id()|pid(), room()) ->
    {ok, room()} | {error, term()}.

destroy_room(Id, Room) ->
    do_call(Id, {destroy_room, Room}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec publish(id()|pid(), room(), nkmedia:offer(), opts()) ->
    {ok, room_user_id(), nkmedia:answer()} | {error, term()}.

publish(Id, Room, Offer, Opts) ->
    do_call(Id, {publish, Room, Offer, Opts}).


%% @doc Starts a conection to a videoroom.
%% caller_id is taked from offer.
-spec unpublish(id()|pid()) ->
    ok | {error, term()}.

unpublish(Id) ->
    do_call(Id, unpublish).


%% @doc Starts a conection to a videoroom
-spec listen(id()|pid(), room(), room_user_id(), opts()) ->
    {ok, nkmedia:offer()} | {error, term()}.

listen(Id, Room, UserId, Opts) ->
    do_call(Id, {listen, Room, UserId, Opts}).


%% @doc Answers a listen
-spec listen_answer(id()|pid(), nkmedia:answer()) ->
    ok | {error, term()}.

listen_answer(Id, Answer) ->
    do_call(Id, {listen_answer, Answer}).


%% @doc Answers a listen
-spec listen_switch(id()|pid(), room_user_id(), opts()) ->
    ok | {error, term()}.

listen_switch(Id, UserId, Opts) ->
    do_call(Id, {listen_switch, UserId, Opts}).


%% @private
-spec get_all() ->
    [{term(), pid()}].

get_all() ->
    nklib_proc:values(?MODULE).



%% ===================================================================
%% Internal
%% ===================================================================

janus_event({?MODULE, Pid}, JanusSessId, JanusHandle, Msg) ->
    gen_server:cast(Pid, {event, JanusSessId, JanusHandle, Msg}).



% ===================================================================
%% gen_server behaviour
%% ===================================================================


-record(state, {
    id :: id(),
    janus_id :: nkmedia_janus:id(),
    opts :: opts(),
    mon :: reference(),
    status = init :: status() | init,
    session_id :: integer(),
    handle_id :: integer(),
    session_id2 :: integer(),
    handle_id2 :: integer(),
    room_id :: integer(),
    from :: {pid(), term()},
    timer :: reference()
}).


%% @private
-spec init(term()) ->
    {ok, tuple()}.

init({Id, JanusId, CallerPid}) ->
    State = #state{
        id = Id, 
        janus_id = JanusId, 
        mon = monitor(process, CallerPid)
    },
    true = nklib_proc:reg({?MODULE, Id}),
    nklib_proc:put(?MODULE, Id),
    self() ! send_keepalive,
    {ok, status(wait, State)}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {noreply, #state{}} | {reply, term(), #state{}} |
    {stop, Reason::term(), #state{}} | {stop, Reason::term(), Reply::term(), #state{}}.

handle_call({videocall, Offer, Opts}, From, #state{status=wait}=State) -> 
    do_videocall(Offer, Opts, From, State);

handle_call({videocall_answer, Answer}, From, 
            #state{status=wait_videocall_answer}=State) ->
    do_videocall_answer(Answer, From, State);

handle_call({echo, Offer, Opts}, _From, #state{status=wait}=State) -> 
    do_echo(Offer, Opts, State);

handle_call(list_rooms, _From, #state{status=wait}=State) -> 
    do_list_rooms(State);

handle_call({create_room, Opts}, _From, #state{status=wait}=State) -> 
    do_create_room(Opts, State);

handle_call({destroy_room, Room}, _From, #state{status=wait}=State) -> 
    do_destroy_room(Room, State);

handle_call({publish, Room, Offer, Opts}, _From, #state{status=wait}=State) -> 
    do_publish(Room, Offer, Opts, State);

handle_call(upublish, _From, #state{status=publish}=State) -> 
    do_unpublish(State);

handle_call({listen, Room, UserId, Opts}, _From, #state{status=wait}=State) -> 
    do_listen(Room, UserId, Opts, State);

handle_call({listen_answer, Answer}, _From, 
            #state{status=wait_listen_answer}=State) -> 
    do_listen_answer(Answer, State);

handle_call({listen_switch, UserId, Opts}, _From, #state{status=listen}=State) -> 
    do_listen_switch(UserId, Opts, State);

handle_call(_Msg, _From, State) -> 
    reply({error, invalid_state}, State).
    

%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({event, _Id, _Handle, stop}, State) ->
    ?LLOG(notice, "received stop from janus", [], State),
    {stop, normal, State};

handle_cast({event, Id, Handle, Msg}, State) ->
    case parse_event(Msg) of
        error ->
            ?LLOG(warning, "unrecognized event: ~p", [Msg], State),
            noreply(State);
        {data, #{<<"echotest">>:=<<"event">>, <<"result">>:=<<"done">>}} ->    
            noreply(State);
        Event ->
            do_event(Id, Handle, Event, State)
    end;

handle_cast(stop, State) ->
    ?LLOG(info, "user stop", [], State),
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {stop, unexpected_call, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info(send_keepalive, #state{session_id=Id1, session_id2=Id2}=State) ->
    case is_integer(Id1) of
        true -> keepalive(Id1, State);
        false -> ok
    end,
    case is_integer(Id2) of
        true -> keepalive(Id2, State);
        false -> ok
    end,
    erlang:send_after(1000*?KEEPALIVE, self(), send_keepalive),
    noreply(State);

handle_info({timeout, _, status_timeout}, State) ->
    ?LLOG(info, "status timeout", [], State),
    {stop, normal, State};

handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{mon=Ref}=State) ->
    case Reason of
        normal ->
            ?LLOG(info, "monitor stop", [], State);
        _ ->
            ?LLOG(notice, "monitor stop: ~p", [Reason], State)
    end,
    {stop, normal, State};

handle_info(Msg, State) -> 
    lager:warning("Module ~p received unexpected info ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, State) ->
    #state{from=From, session_id=Id, session_id2=Id2} = State,
    case Id of
        undefined -> ok;
        _ -> destroy(Id, State)
    end,
    case Id2 of
        undefined -> ok;
        _ -> destroy(Id2, State)
    end,
    nklib_util:reply(From, {error, stopped}),
    ok.


% ===================================================================
%% Videocall
%% ===================================================================

%% @private First node registers
do_videocall(#{sdp:=SDP}, Opts, From, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videocall, State),
    UserName = nklib_util:to_binary(Handle),
    Body = #{request=>register, username=>UserName},
    case message(Id, Handle, Body, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{
                session_id = Id,
                handle_id = Handle,
                from = From,
                opts = Opts
            },
            do_videocall_2(SDP, State2);
        {error, Error} ->
            reply_error({could_not_register, Error}, State)
    end.


%% @private Second node registers
do_videocall_2(SDP, State) ->
    {ok, Id2} = create(State),
    {ok, Handle2} = attach(Id2, <<"videocall">>, State),
    UserName2 = nklib_util:to_binary(Handle2),
    Body = #{request=>register, username=>UserName2},
    case message(Id2, Handle2, Body, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"registered">>}}, _} ->
            State2 = State#state{
                session_id2 = Id2,
                handle_id2 = Handle2
            },
            do_videocall_3(SDP, State2);
        {error, Error} ->
            reply({could_not_register, Error}, State)
    end.


%% @private We launch the call and wait for Juanus
do_videocall_3(SDP, State) ->
    #state{
        session_id = Id, 
        handle_id = Handle, 
        handle_id2 = Handle2
    } = State,
    Body = #{request=>call, username=>nklib_util:to_binary(Handle2)},
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"calling">>}}, _} ->
            {noreply, status(wait_videocall_offer, State)};
        {error, Error} ->
            reply_error({could_not_call, Error}, State)
    end.


%% @private. We receive answer from called party and wait Janus
do_videocall_answer(#{sdp:=SDP}, From, State) ->
    #state{session_id2=Id, handle_id2=Handle} = State,
    Body = #{request=>accept},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"result">>:=#{<<"event">>:=<<"accepted">>}}, _} ->
            Body2 = #{
                request => set,
                audio => true,
                video => true,
                bitrate => 0,
                record => true,
                filename => <<"/tmp/call_b">>
            },
            case message(Id, Handle, Body2, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=From},
                    noreply(status(wait_videocall_reply, State2));
                {error, Error} ->
                    reply_error({set_error, Error}, State)
            end;
        {error, Error} ->
            reply_error({accepted_error, Error}, State)
    end.



% ===================================================================
%% Echo
%% ===================================================================

%% @private Echo plugin
do_echo(#{sdp:=SDP}, Opts, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, echotest, State),
    Body1 = #{audio => true, video => true},
    Body2 = update_body(Body1, Opts),
    Jsep = #{sdp=>SDP, type=>offer, trickle=>false},
    case message(Id, Handle, Body2, Jsep, State) of
        {ok, #{<<"result">>:=<<"ok">>}, #{<<"sdp">>:=SDP2}} ->
            State2 = State#state{session_id=Id, handle_id=Handle},
            reply({ok, #{sdp=>SDP2}}, status(echo, State2));
        {error, Error} ->
            reply_error({echo_error, Error}, State)
    end.


% ===================================================================
%% Rooms
%% ===================================================================

%% @private
do_list_rooms(State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videoroom, State),
    Body = #{request => list}, 
    case message(Id, Handle, Body, State) of
        {ok, #{<<"list">>:=List}, _} ->
            reply_stop({ok, List}, State);
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.


%% @private
do_create_room(Opts, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videoroom, State),
    Body = #{
        request => create, 
        description => nklib_util:to_binary(maps:get(description, Opts, <<>>)),
        bitrate => maps:get(bitrate, Opts, 128000),
        publishers => maps:get(publishers, Opts, 6),
        audiocodec => maps:get(audiocodec, Opts, opus),
        videocodec => maps:get(videocodec, Opts, vp8),
        record => maps:get(record, Opts, false),
        rec_dir => nklib_util:to_binary(maps:get(rec_dir, Opts, <<"/tmp">>)),
        is_private => false,
        permanent => false
        % fir_freq
        % room => you can select id 
    },
    case message(Id, Handle, Body, State) of
        {ok, #{<<"videoroom">>:=<<"created">>, <<"room">>:=Room}, _} ->
            reply_stop({ok, Room}, State);
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.


%% @private
do_destroy_room(Room, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videoroom, State),
    Body = #{
        request => destroy,
        room => Room 
    },
    case message(Id, Handle, Body, State) of
        {ok, #{<<"videoroom">>:=<<"destroyed">>}, _} ->
            reply({ok, Room}, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            reply_error({create_error, Error}, State)
    end.





% ===================================================================
%% Publisher
%% ===================================================================

%% @private Create session and join
do_publish(Room, #{sdp:=SDP}=Offer, Opts, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videoroom, State),
    Display = maps:get(caller_id, Offer, <<"undefined">>),
    Body = #{
        request => join, 
        room => Room,
        ptype => publisher,
        display => nklib_util:to_binary(Display)
        % id 
    },
    case message(Id, Handle, Body, State) of
        {ok, #{<<"videoroom">>:=<<"joined">>, <<"id">>:=UserId}, _} ->
            State2 = State#state{session_id=Id, handle_id=Handle, opts=Opts},
            do_publish_2(UserId, SDP, State2);
        {error, Error} ->
            reply_error({joined_error, Error}, State)
    end.


%% @private
do_publish_2(UserId, SDP_A, State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    Body = #{
        request => configure,
        audio => true,
        video => true
        % bitrate
        % record
        % filename
    },
    Jsep = #{sdp=>SDP_A, type=>offer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"configured">>:=<<"ok">>}, #{<<"sdp">>:=SDP_B}} ->
            reply({ok, UserId, #{sdp=>SDP_B}}, status(publish, State));
        {error, Error} ->
            reply_error({configure_error, Error}, State)
    end.


%% @private
do_unpublish(State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    Body = #{request => unpublish},
    case message(Id, Handle, Body, State) of
        {ok, #{<<"videoroom">>:=<<"unpublished">>}, _} ->
            reply(ok, State);
        {error, Error} ->
            reply_error({joined_error, Error}, State)
    end.





% ===================================================================
%% Listener
%% ===================================================================


%% @private Create session and join
do_listen(Room, UserId, Opts, State) ->
    {ok, Id} = create(State),
    {ok, Handle} = attach(Id, videoroom, State),
    Body = #{
        request => join, 
        room => Room,
        ptype => listener,
        feed => UserId
        % audio
        % video
        % data
    },
    case message(Id, Handle, Body, State) of
        {ok, #{<<"videoroom">>:=<<"attached">>}, #{<<"sdp">>:=SDP}} ->
            State2 = State#state{
                session_id = Id, 
                handle_id = Handle,
                room_id = Room,
                opts = Opts
            },
            reply({ok, #{sdp=>SDP}}, status(wait_listen_answer, State2));
        {ok, #{<<"error">>:=Error}, _} ->
            reply_error(Error, State);
        {error, Error} ->
            {error, {could_not_join, Error}}
    end.


%% @private Caller answers
do_listen_answer(#{sdp:=SDP}, State) ->
    #state{session_id=Id, handle_id=Handle, room_id=Room} = State,
    Body = #{request=>start, room=>Room},
    Jsep = #{sdp=>SDP, type=>answer, trickle=>false},
    case message(Id, Handle, Body, Jsep, State) of
        {ok, #{<<"started">>:=<<"ok">>}, _} ->
            reply(ok, status(listen, State));
        {error, Error} ->
            reply_error({start_error, Error}, State)
    end.



%% @private Create session and join
do_listen_switch(UserId, Opts, State) ->
    #state{session_id=Id, handle_id=Handle} = State,
    Body = #{
        request => switch,        
        feed => UserId,
        audio => maps:get(audio, Opts, true),
        video => maps:get(video, Opts, true),
        data => maps:get(data, Opts, true)
    },
    case message(Id, Handle, Body, State) of
        {ok, #{<<"switched">>:=<<"ok">>}, _} ->
            reply(ok, State);
        {ok, #{<<"error">>:=Error}, _} ->
            reply({error, Error}, State);
        {error, Error} ->
            {error, {could_not_join, Error}}
    end.



% ===================================================================
%% Events
%% ===================================================================

%% @private
do_event(Id, Handle, {event, <<"incomingcall">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status=wait_videocall_offer, session_id2=Id, handle_id2=Handle} ->
            #state{from=From} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            State2 = State#state{from=undefined},
            noreply(status(wait_videocall_answer, State2));
        _ ->
            ?LLOG(warning, "unexpected incomingcall!", [], State),
            {stop, normal, State}
    end;

do_event(Id, Handle, {event, <<"accepted">>, _, #{<<"sdp">>:=SDP}}, State) ->
    case State of
        #state{status=wait_videocall_reply, session_id=Id, handle_id=Handle} ->
            #state{from=From, opts=Opts} = State,
            gen_server:reply(From, {ok, #{sdp=>SDP}}),
            Body1 = #{request => set, audio => true, video => true},
            Body2 = update_body(Body1, Opts),
            case message(Id, Handle, Body2, State) of
                {ok, #{<<"result">>:=#{<<"event">>:=<<"set">>}}, _} ->
                    State2 = State#state{from=undefined},
                    noreply(status(videocall, State2));
                {error, Error} ->
                    ?LLOG(warning, "error sending set: ~p", [Error], State),
                    {stop, normal, State}
            end;
        _ ->
            ?LLOG(warning, "unexpected incomingcall!", [], State),
            {stop, normal, State}
    end;

do_event(_Id, _Handle, Event, State) ->
    ?LLOG(info, "unexpected event: ~p", [Event], State),
    noreply(State).




% ===================================================================
%% Internal
%% ===================================================================

%% @private
create(State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:create(Pid, ?MODULE, {?MODULE, self()}).


%% @private
attach(SessId, Plugin, State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:attach(Pid, SessId, nklib_util:to_binary(Plugin)).


%% @private
message(SessId, Handle, Body, State) ->
    message(SessId, Handle, Body, #{}, State).


%% @private
message(SessId, Handle, Body, Jsep, State) ->
    {ok, Pid} = get_janus_pid(State),
    case nkmedia_janus_client:message(Pid, SessId, Handle, Body, Jsep) of
        {ok, #{<<"data">>:=Data}, Jsep2} ->
            {ok, Data, Jsep2};
        {error, Error} ->
            {error, Error}
    end.


%% @private
destroy(SessId, State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:destroy(Pid, SessId).


%% @private
keepalive(SessId, State) ->
    {ok, Pid} = get_janus_pid(State),
    nkmedia_janus_client:keepalive(Pid, SessId).


%% @private
get_janus_pid(#state{janus_id=JanusId}) ->
    nkmedia_janus_engine:get_conn(JanusId).


%% @private
parse_event(Msg) ->
    Jsep = maps:get(<<"jsep">>, Msg, #{}),
    case Msg of
        #{
            <<"plugindata">> := #{
                <<"data">> := #{
                    <<"result">> := #{<<"event">> := Event} = Result
                }
            }
        } ->
            {event, Event, Result, Jsep};
        #{<<"plugindata">> := #{<<"data">> := Data}} ->
            {data, Data};
        _ ->
            error
    end.


%% @private
update_body(Body, Opts) ->
    Body2 = case Opts of
        #{bitrate:=Bitrate} ->
            Body#{bitrate=>Bitrate};
        _ ->
            Body
    end,
    case Opts of
        #{record:=true, filename:=File} ->
            Body2#{record=>true, filename=>nklib_util:to_binary(File)};
        _ ->
            Body2
    end.


%% @private
status(NewStatus, #state{timer=Timer}=State) ->
    ?LLOG(info, "status changed to ~p", [NewStatus], State),
    nklib_util:cancel_timer(Timer),
    Time = case NewStatus of
        echo -> ?CALL_TIMEOUT;
        videocall -> ?CALL_TIMEOUT;
        publish -> ?CALL_TIMEOUT;
        listen -> ?CALL_TIMEOUT;
        _ -> ?OP_TIMEOUT
    end,
    NewTimer = erlang:start_timer(1000*Time, self(), status_timeout),
    State#state{status=NewStatus, timer=NewTimer}.


%% @private
reply(Reply, State) ->
    {reply, Reply, State, get_hibernate(State)}.


%% @private
reply_stop(Reply, State) ->
    {stop, normal, Reply, State}.


%% @private
reply_error(Error, State) ->
    {stop, normal, {error, Error}, State}.


%% @private
noreply(State) ->
    {noreply, State, get_hibernate(State)}.


%% @private
get_hibernate(#state{status=Status})
    when Status==echo; Status==videocall; 
         Status==publish; Status==listen ->
    hibernate;
get_hibernate(_) ->
    infinity.


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(SessId) ->
    case nklib_proc:values({?MODULE, SessId}) of
        [{undefined, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_call(SessId, Msg) ->
    do_call(SessId, Msg, 1000*?RING_TIMEOUT).


%% @private
do_call(SessId, Msg, Timeout) ->
    case find(SessId) of
        {ok, Pid} -> 
            nklib_util:call(Pid, Msg, Timeout);
        not_found -> 
            case start(SessId) of
                {ok, _, Pid} ->
                    nklib_util:call(Pid, Msg, Timeout);
                _ ->
                    {error, session_not_found}
            end
    end.


%% @private
do_cast(SessId, Msg) ->
    case find(SessId) of
        {ok, Pid} -> gen_server:cast(Pid, Msg);
        not_found -> {error, session_not_found}
    end.

