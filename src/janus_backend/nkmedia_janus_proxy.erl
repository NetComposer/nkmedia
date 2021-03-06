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

%% @doc Plugin implementing a Kurento proxy server for testing
-module(nkmedia_janus_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2, 
         plugin_start/2, plugin_stop/2]).
-export([nkmedia_janus_proxy_init/2, nkmedia_janus_proxy_find_janus/2,
         nkmedia_janus_proxy_in/2, nkmedia_janus_proxy_out/2, 
         nkmedia_janus_proxy_terminate/2, nkmedia_janus_proxy_handle_call/3,
         nkmedia_janus_proxy_handle_cast/2, nkmedia_janus_proxy_handle_info/2]).


-define(WS_TIMEOUT, 60*60*1000).
-include_lib("nkservice/include/nkservice.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type state() :: term().
-type continue() :: continue | {continue, list()}.


%% ===================================================================
%% Plugin callbacks
%% ===================================================================


plugin_deps() ->
    [nkmedia_janus].


plugin_syntax() ->
    nkpacket:register_protocol(janus_proxy, nkmedia_janus_proxy_server),
    #{
        janus_proxy => fun parse_listen/3
    }.


plugin_listen(Config, #{id:=SrvId}) ->
    % janus_proxy will be already parsed
    Listen = maps:get(janus_proxy, Config, []),
    % With the 'user' parameter we tell nkmedia_kurento protocol
    % to use the service callback module, so it will find
    % nkmedia_kurento_* funs there.
    Opts = #{
        class => {nkmedia_janus_proxy, SrvId},
        idle_timeout => ?WS_TIMEOUT,
        ws_proto => <<"janus-protocol">>
    },                                  
    [{Conns, maps:merge(ConnOpts, Opts)} || {Conns, ConnOpts} <- Listen].
    


plugin_start(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proxy (~s) starting", [Name]),
    {ok, Config}.


plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin NkMEDIA JANUS Proxy (~p) stopping", [Name]),
    {ok, Config}.



%% ===================================================================
%% Offering callbacks
%% ===================================================================



%% @doc Called when a new KMS proxy connection arrives
-spec nkmedia_janus_proxy_init(nkpacket:nkport(), state()) ->
    {ok, state()}.

nkmedia_janus_proxy_init(_NkPort, State) ->
    {ok, State}.


%% @doc Called to select a KMS server
-spec nkmedia_janus_proxy_find_janus(nkmedia_service:id(), state()) ->
    {ok, [nkmedia_janus_engine:id()], state()}.

nkmedia_janus_proxy_find_janus(SrvId, State) ->
    List = [Name || {Name, _} <- nkmedia_janus_engine:get_all(SrvId)],
    {ok, List, State}.


%% @doc Called when a new msg arrives
-spec nkmedia_janus_proxy_in(map(), state()) ->
    {ok, map(), state()} | {stop, term(), state()} | continue().

nkmedia_janus_proxy_in(Msg, State) ->
    {ok, Msg, State}.


%% @doc Called when a new msg is to be answered
-spec nkmedia_janus_proxy_out(map(), state()) ->
    {ok, map(), state()} | {stop, term(), state()} | continue().

nkmedia_janus_proxy_out(Msg, State) ->
    {ok, Msg, State}.


%% @doc Called when the connection is stopped
-spec nkmedia_janus_proxy_terminate(Reason::term(), state()) ->
    {ok, state()}.

nkmedia_janus_proxy_terminate(_Reason, State) ->
    {ok, State}.


%% @doc 
-spec nkmedia_janus_proxy_handle_call(Msg::term(), {pid(), term()}, state()) ->
    {ok, state()} | continue().

nkmedia_janus_proxy_handle_call(Msg, _From, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc 
-spec nkmedia_janus_proxy_handle_cast(Msg::term(), state()) ->
    {ok, state()}.

nkmedia_janus_proxy_handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc 
-spec nkmedia_janus_proxy_handle_info(Msg::term(), state()) ->
    {ok, State::map()}.

nkmedia_janus_proxy_handle_info(Msg, State) ->
    lager:error("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.





%% ===================================================================
%% Internal
%% ===================================================================


parse_listen(_Key, [{[{_, _, _, _}|_], Opts}|_]=Multi, _Ctx) when is_map(Opts) ->
    {ok, Multi};

parse_listen(janus_proxy, Url, _Ctx) ->
    Opts = #{valid_schemes=>[janus_proxy], resolve_type=>listen},
    case nkpacket:multi_resolve(Url, Opts) of
        {ok, List} -> {ok, List};
        _ -> error
    end.





