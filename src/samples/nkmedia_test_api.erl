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

%% @doc Testing the media API
%% After testing the media system form the Erlang interface (nkmedia_test)
%% here we test sending everything through the API interface.
%%
%% When Verto or Janus call to the machine (e, fe, p, m1, etc.) they start a new
%% API connection, and create the session over it. They program the event system
%% so that answers and stops are detected in api_client_fun.
%% If they send BYE, verto_bye and janus_by are overloaded to stop the session.
%% If the sesison stops, the stop event is detected at nkmedia_api_events and
%% an API event is sent, and captured in api_client_fun.
%%
%% For a listener, start_invite is used, that generates a session over the API,
%% gets the offer over the wire a do a standard (as in nkmedia_test) invite, directly
%% to the session and without API. However, when Verto or Janus replies, the 
%% answer is capured here and sent over the wire.
%% 

-module(nkmedia_test_api).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile([export_all]).

-define(LOG_SAMPLE(Type, Txt, Args, State),
    lager:Type("API Sample (~s) "++Txt, [maps:get(user, State) | Args])).

-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nksip/include/nksip.hrl").


-define(URL1, "nkapic://127.0.0.1:9010").
-define(URL2, "nkapic://c2.netc.io:9010").


%% ===================================================================
%% Public
%% ===================================================================


start() ->
    Spec1 = #{
        callback => ?MODULE,
        plugins => [nkmedia_janus, nkmedia_fs, nkmedia_kms],  %% Call janus->fs->kms
        web_server => "https:all:8081",
        web_server_path => "./www",
        api_server => "wss:all:9010",
        api_server_timeout => 180,
        verto_listen => "verto:all:8082",
        verto_proxy => "verto_proxy:all:8083",
        janus_listen => "janus:all:8989", 
        janus_proxy=> "janus_proxy:all:8990",
        kurento_proxy => "kms:all:8433",
        nksip_trace => {console, all},
        sip_listen => "sip:all:9012",
        log_level => debug,
        api_gelf_server => "c2.netc.io"
    },
    % export NKMEDIA_CERTS="/etc/letsencrypt/live/casa.carlosj.net"
    Spec2 = case os:getenv("NKMEDIA_CERTS") of
        false ->
            Spec1;
        Dir ->
            Spec1#{
                tls_certfile => filename:join(Dir, "cert.pem"),
                tls_keyfile => filename:join(Dir, "privkey.pem"),
                tls_cacertfile => filename:join(Dir, "fullchain.pem")
            }
    end,
    nkservice:start(test, Spec2).


stop() ->
    nkservice:stop(test).

restart() ->
    stop(),
    timer:sleep(100),
    start().




%% ===================================================================
%% Config callbacks
%% ===================================================================


plugin_deps() ->
    [
        nkmedia_sip, nksip_registrar, nksip_trace,
        nkmedia_verto, nkmedia_janus_proto,
        nkmedia_fs, nkmedia_kms, nkmedia_janus,
        nkmedia_fs_verto_proxy, 
        nkmedia_janus_proxy, 
        nkmedia_kms_proxy,
        nkservice_api_gelf,
        nkmedia_room_msglog
    ].




%% ===================================================================
%% Cmds
%% ===================================================================

%% Connect

connect(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL1, User, "p1", Fun, Data),
    C.

connect2(User, Data) ->
    Fun = fun ?MODULE:api_client_fun/2,
    {ok, _, C} = nkservice_api_client:start(test, ?URL2, User, "p1", Fun, Data),
    C.

get_client() ->
    [{_, C}|_] = nkservice_api_client:get_all(),
    C.


%% Session
media(C, S, Data) ->
    cmd(C, S, update_media, Data).

recorder(C, S, Data) ->
    cmd(C, S, recorder_action, Data).

player(C, S, Data) ->
    cmd(C, S, player_action, Data).

room(C, S, Data) ->
    cmd(C, S, room_action, Data).

type(C, S, Type, Data) ->
    cmd(C, S, set_type, Data#{type=>Type}).

% get_offer, get_answer, get_info, destroy, get_list, switch
cmd(C, SessId, Cmd) ->
    cmd(C, SessId, Cmd, #{}).

cmd(C, SessId, Cmd, Data) ->
    Data2 = Data#{session_id=>SessId},
    nkservice_api_client:cmd(C, media, session, Cmd, Data2).

candidate(C, SessId, #candidate{last=true}) ->
    cmd(C, SessId, set_candidate_end, #{});

candidate(C, SessId, #candidate{a_line=Line, m_id=Id, m_index=Index}) ->
    Data = #{sdpMid=>Id, sdpMLineIndex=>Index, candidate=>Line},
    cmd(C, SessId, set_candidate, Data).



%% Room
room_list(C) ->
    room_cmd(C, list, #{}).

room_create(C, Data) ->
    room_cmd(C, create, Data).

room_destroy(C, Id) ->
    room_cmd(C, destroy, #{room_id=>Id}).

room_info(C, Id) ->
    room_cmd(C, info, #{room_id=>Id}).

room_cmd(C, Cmd, Data) ->
    nkservice_api_client:cmd(C, media, room, Cmd, Data).


%% Events

subscribe(WsPid, SessId, Body) ->
    Data = #{class=>media, subclass=>session, obj_id=>SessId, body=>Body},
    nkservice_api_client:cmd(WsPid, core, event, subscribe, Data).


subscribe_all(WsPid) ->
    Data = #{class=>media},
    nkservice_api_client:cmd(WsPid, core, event, subscribe, Data).




%% Invite
invite(Dest, Type, Opts) ->
    WsPid = get_client(),
    start_invite(Dest, WsPid, Opts#{type=>Type}).

invite_listen(Dest, Room, Pos) ->
    {ok, PubId, Backend} = nkmedia_test:get_publisher(Room, Pos),
    invite(Dest, listen, #{backend=>Backend, publisher_id=>PubId}).

switch(SessId, Pos) ->
    {ok, listen, #{room_id:=Room}, _} = nkmedia_session:get_type(SessId),
    {ok, PubId, _Backend} = nkmedia_test:get_publisher(Room, Pos),
    C = get_client(),
    type(C, SessId, listen, #{publisher_id=>PubId}).



%% Msglog
msglog_send(C, Room, Msg) ->
    nkservice_api_client:cmd(C, media, room, msglog_send, #{room_id=>Room, msg=>Msg}).

msglog_get(C, Room) ->
    nkservice_api_client:cmd(C, media, room, msglog_get, #{room_id=>Room}).

msglog_subscribe(C, Room) ->
    Spec = #{class=>media, subclass=>room, obj_id=>Room},
    nkservice_api_client:cmd(C, core, event, subscribe, Spec).


%% Gelf
gelf(C, Src, Short) ->
    Msg = #{
        source => Src,
        message => Short,
        full_message => base64:encode(crypto:rand_bytes(10))
    },
    nkservice_api_client:cmd(C, core, session, log, Msg).



 

%% ===================================================================
%% api server callbacks
%% ===================================================================


%% @doc Called on login
api_server_login(#{<<"user">>:=User}, _SessId, State) ->
    nkservice_api_server:start_ping(self(), 60),
    {true, User, State};

api_server_login(_Data, _SessId, _State) ->
    continue.


%% @doc
api_allow(_Req, State) ->
    {true, State}.


%% @oc
api_subscribe_allow(_SrvId, _Class, _SubClass, _Type, State) ->
    {true, State}.




%% ===================================================================
%% nkmedia_verto callbacks
%% ===================================================================

%% @private
nkmedia_verto_login(Login, Pass, Verto) ->
    case nkmedia_test:nkmedia_verto_login(Login, Pass, Verto) of
        {true, User, Verto2} ->
            Pid = connect(User, #{test_verto_server=>self()}),
            {true, User, Verto2#{test_api_server=>Pid}};
        Other ->
            Other
    end.


% @private Called when we receive INVITE from Verto
nkmedia_verto_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Verto) ->
    #{dest:=Dest} = Offer,
    Events = #{
        verto_call_id => CallId,
        verto_pid => pid2bin(self())
    },
    case incoming(Dest, Offer, Ws, Events, #{no_answer_trickle_ice => true}) of
        {ok, SessId, _SessPid} ->
            % we don't use {nkmedia_session, SessId, SessPid} as link,
            % to emulate the API situation
            {ok, {api_test_session, SessId, Ws}, Verto};
        {error, Reason} ->
            lager:notice("Verto invite rejected ~p", [Reason]),
            {rejected, Reason, Verto}
    end;

nkmedia_verto_invite(_SrvId, _CallId, _Offer, _Verto) ->
    continue.


%% @private
nkmedia_verto_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                     #{test_api_server:=Ws}=Verto) ->
    {ok, _} = cmd(Ws, SessId, set_answer, #{answer=>Answer}),
    {ok, Verto};

nkmedia_verto_answer(_CallId, _Link, _Answer, Verto) ->
    {ok, Verto}.


% @private Called when we receive BYE from Verto
nkmedia_verto_bye(_CallId, {api_test_session, SessId, WsPid}, Verto) ->
    #{test_api_server:=WsPid} = Verto,
    lager:info("Verto Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = cmd(WsPid, SessId, destroy),
    {ok, Verto};

nkmedia_verto_bye(_CallId, _Link, _Verto) ->
    continue.

%% @private
nkmedia_verto_terminate(_Reason, #{test_api_server:=Pid}=Verto) ->
    nkservice_api_client:stop(Pid),
    {ok, Verto};

nkmedia_verto_terminate(_Reason, Verto) ->
    {ok, Verto}.



%% ===================================================================
%% nkmedia_janus_proto callbacks
%% ===================================================================

%% @private
nkmedia_janus_registered(User, Janus) ->
    Pid = connect(User, #{test_janus_server=>self()}),
    {ok, Janus#{test_api_server=>Pid}}.


% @private Called when we receive INVITE from Janus
nkmedia_janus_invite(_SrvId, CallId, Offer, #{test_api_server:=Ws}=Janus) ->
    #{dest:=Dest} = Offer,
    Events = #{
        janus_call_id => CallId,
        janus_pid => pid2bin(self())
    },
    case incoming(Dest, Offer, Ws, Events, #{no_answer_trickle_ice => true}) of
        {ok, SessId, _SessPid} ->
            {ok, {api_test_session, SessId, Ws}, Janus};
        {error, Reason} ->
            lager:notice("Janus invite rejected: ~p", [Reason]),
            {rejected, Reason, Janus}
    end.


%% @private
nkmedia_janus_candidate(_CallId, {api_test_session, SessId, WsPid}, Candidate, Janus) ->
    {ok, _} = candidate(WsPid, SessId, Candidate),
    {ok, Janus};

nkmedia_janus_candidate(_CallId, _Link, _Candidate, _Janus) ->
    continue.


%% @private
nkmedia_janus_answer(_CallId, {nkmedia_session, SessId, _Pid}, Answer, 
                     #{test_api_server:=Ws}=Janus) ->
    {ok, _} = cmd(Ws, SessId, set_answer, #{answer=>Answer}),
    {ok, Janus};

nkmedia_janus_answer(_CallId, _Link, _Answer, Janus) ->
    {ok, Janus}.


%% @private BYE from Janus
nkmedia_janus_bye(_CallId, {api_test_session, SessId, WsPid}, Janus) ->
    lager:notice("Janus Session BYE for ~s (~p)", [SessId, WsPid]),
    {ok, _} = cmd(WsPid, SessId, destroy),
    {ok, Janus};

nkmedia_janus_bye(_CallId, _Link, _Janus) ->
    continue.


%% @private
nkmedia_janus_terminate(_Reason, #{test_api_server:=Pid}=Janus) ->
    nkservice_api_client:stop(Pid),
    {ok, Janus};

nkmedia_janus_terminate(_Reason, Janus) ->
    {ok, Janus}.





%% ===================================================================
%% Internal
%% ===================================================================

%% @private
incoming(<<"je">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_janus, echo, Offer, Events, Opts),
    start_session(WsPid, Config#{bitrate=>100000, mute_audio=>false});

incoming(<<"fe">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_fs, echo, Offer, Events, Opts),
    start_session(WsPid, Config);

incoming(<<"ke">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_kms, echo, Offer, Events, Opts),
    start_session(WsPid, Config#{mute_audio=>true});

incoming(<<"m1">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_fs, mcu, Offer, Events, Opts#{room_id=>m1}),
    start_session(WsPid, Config);

incoming(<<"m2">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_fs, mcu, Offer, Events, Opts#{room_id=>m2}),
    start_session(WsPid, Config);

incoming(<<"jp1">>, Offer, WsPid, Events, Opts) ->
    RoomConfig = #{class=>sfu, room_id=>sfu, backend=>nkmedia_janus, bitrate=>100000},
    case room_create(WsPid, RoomConfig) of
        {ok, _} -> ok;
        {error, {304002, _}} -> ok
    end,
    Config = incoming_config(nkmedia_janus, publish, Offer, Events, Opts),
    start_session(WsPid, Config#{room_id=>sfu});

incoming(<<"jp2">>, Offer, WsPid, Events, Opts) ->
    Config1 = incoming_config(nkmedia_janus, publish, Offer, Events, Opts),
    Config2 = Config1#{
        room_audio_codec => pcma,
        room_video_codec => vp9,
        room_bitrate => 100000
    },
    start_session(WsPid, Config2#{room_id=>sfu2});

incoming(<<"kp1">>, Offer, WsPid, Events, Opts) ->
    RoomConfig = #{class=>sfu, room_id=>sfu, backend=>nkmedia_kms},
    case room_create(WsPid, RoomConfig) of
        {ok, _} -> ok;
        {error, {304002, _}} -> ok
    end,
    Config = incoming_config(nkmedia_kms, publish, Offer, Events, Opts),
    start_session(WsPid, Config#{room_id=>sfu});

incoming(<<"kp2">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_kms, publish, Offer, Events, Opts),
    start_session(WsPid, Config#{room_id=>sfu2});

incoming(<<"play">>, Offer, WsPid, Events, Opts) ->
    Config = incoming_config(nkmedia_kms, play, Offer, Events, Opts),
    start_session(WsPid, Config);

incoming(_, _Offer, _WsPid, _Events, _Opts) ->
    {error, no_destination}.



%% @private
incoming_config(Backend, Type, Offer, Events, Opts) ->
    Opts#{
        backend => Backend, 
        type => Type, 
        offer => Offer, 
        events_body => Events
    }.


start_session(WsPid, Config) when is_pid(WsPid) ->
    case nkservice_api_client:cmd(WsPid, media, session, create, Config) of
        {ok, #{<<"session_id">>:=SessId}} -> 
            {ok, SessPid} = nkmedia_session:find(SessId),
            {ok, SessId, SessPid};
            % {ok, {api_test_session, SessId, WsPid}};
        {error, {_Code, Txt}} -> 
            {error, Txt}
    end.


%% @private
start_invite(Num, WsPid, Config) ->
    case  nkmedia_test:find_user(Num) of
        not_found ->
            {error, unknown_user};
        Dest ->
            Config2 = Config#{no_offer_trickle_ice=>true},
            {ok, SessId, SessPid} = start_session(WsPid, Config2),
            {ok, Offer} = cmd(WsPid, SessId, get_offer),
            SessLink = {nkmedia_session, SessId, SessPid},
            Syntax = nkmedia_api_syntax:offer(),
            {ok, Offer2, _} = nklib_config:parse_config(Offer, Syntax, #{return=>map}),
            start_invite2(Dest, SessId, Offer2, SessLink)
    end.


%% @private
start_invite2({nkmedia_verto, VertoPid}, SessId, Offer, SessLink) ->
    {ok, InvLink} = nkmedia_verto:invite(VertoPid, SessId, Offer, SessLink),
    {ok, _} = nkmedia_session:register(SessId, InvLink);

start_invite2({nkmedia_janus, JanusPid}, SessId, Offer, SessLink) ->
    {ok, InvLink} = nkmedia_janus_proto:invite(JanusPid, SessId, Offer, SessLink),
    {ok, _} = nkmedia_session:register(SessId, InvLink).



%% @private
api_client_fun(#api_req{class = <<"core">>, cmd = <<"event">>, data = Data}, UserData) ->
    Class = maps:get(<<"class">>, Data),
    Sub = maps:get(<<"subclass">>, Data, <<"*">>),
    Type = maps:get(<<"type">>, Data, <<"*">>),
    ObjId = maps:get(<<"obj_id">>, Data, <<"*">>),
    Body = maps:get(<<"body">>, Data, #{}),
    Sender = case Body of
        #{
            <<"verto_call_id">> := SCallId,
            <<"verto_pid">> := BinPid
        } ->
            {verto, SCallId, bin2pid(BinPid)};
        #{
            <<"janus_call_id">> := SCallId,
            <<"janus_pid">> := BinPid
        } ->
            {janus, SCallId,  bin2pid(BinPid)};
        _ ->
            unknown
    end,
    case {Class, Sub, Type} of
        {<<"media">>, <<"session">>, <<"answer">>} ->
            #{<<"answer">>:=#{<<"sdp">>:=SDP}} = Body,
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:answer(Pid, CallId, #{sdp=>SDP});
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:answer(Pid, CallId, #{sdp=>SDP});
                unknown ->
                    lager:notice("TEST CLIENT ANSWER")
            end;
        {<<"media">>, <<"session">>, <<"destroyed">>} ->
            case Sender of
                {verto, CallId, Pid} ->
                    nkmedia_verto:hangup(Pid, CallId);
                {janus, CallId, Pid} ->
                    nkmedia_janus_proto:hangup(Pid, CallId);
                unknown ->
                    lager:notice("TEST CLIENT SESSION STOP: ~p", [Data])
            end;
        _ ->
            lager:notice("TEST CLIENT event ~s:~s:~s:~s: ~p", 
                         [Class, Sub, Type, ObjId, Body])
    end,
    {ok, #{}, UserData};

api_client_fun(_Req, UserData) ->
    lager:error("TEST CLIENT req: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, UserData}.


pid2bin(Pid) -> list_to_binary(pid_to_list(Pid)).
bin2pid(Bin) -> list_to_pid(binary_to_list(Bin)).
