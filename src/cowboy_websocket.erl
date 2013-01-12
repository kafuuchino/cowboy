%% Copyright (c) 2011-2013, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @doc Websocket protocol implementation.
%%
%% Cowboy supports versions 7 through 17 of the Websocket drafts.
%% It also supports RFC6455, the proposed standard for Websocket.
-module(cowboy_websocket).

%% API.
-export([upgrade/4]).

%% Internal.
-export([handler_loop/4]).

-type frame() :: close | ping | pong
	| {text | binary | close | ping | pong, binary()}
	| {close, 1000..4999, binary()}.
-export_type([frame/0]).

-type opcode() :: 0 | 1 | 2 | 8 | 9 | 10.
-type mask_key() :: 0..16#ffffffff.

%% The websocket_data/4 function may be called multiple times for a message.
%% The websocket_dispatch/4 function is only called once for each message.
-type frag_state() ::
	undefined | %% no fragmentation has been seen.
	{nofin, opcode()} | %% first fragment has been seen.
	{nofin, opcode(), binary()} | %% first fragment has been unmasked.
	{fin, opcode(), binary()}. %% last fragment has been seen.

-record(state, {
	env :: cowboy_middleware:env(),
	socket = undefined :: inet:socket(),
	transport = undefined :: module(),
	handler :: module(),
	handler_opts :: any(),
	key = undefined :: undefined | binary(),
	timeout = infinity :: timeout(),
	timeout_ref = undefined :: undefined | reference(),
	messages = undefined :: undefined | {atom(), atom(), atom()},
	hibernate = false :: boolean(),
	frag_state = undefined :: frag_state()
}).

%% @doc Upgrade an HTTP request to the Websocket protocol.
%%
%% You do not need to call this function manually. To upgrade to the Websocket
%% protocol, you simply need to return <em>{upgrade, protocol, {@module}}</em>
%% in your <em>cowboy_http_handler:init/3</em> handler function.
-spec upgrade(Req, Env, module(), any())
	-> {ok, Req, Env} | {error, 400, Req}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req(), Env::cowboy_middleware:env().
upgrade(Req, Env, Handler, HandlerOpts) ->
	{_, ListenerPid} = lists:keyfind(listener, 1, Env),
	ranch_listener:remove_connection(ListenerPid),
	[Socket, Transport] = cowboy_req:get([socket, transport], Req),
	State = #state{env=Env, socket=Socket, transport=Transport,
		handler=Handler, handler_opts=HandlerOpts},
	case catch websocket_upgrade(State, Req) of
		{ok, State2, Req2} -> handler_init(State2, Req2);
		{'EXIT', _Reason} -> upgrade_error(Req, Env)
	end.

-spec websocket_upgrade(#state{}, Req)
	-> {ok, #state{}, Req} when Req::cowboy_req:req().
websocket_upgrade(State, Req) ->
	{ok, ConnTokens, Req2}
		= cowboy_req:parse_header(<<"connection">>, Req),
	true = lists:member(<<"upgrade">>, ConnTokens),
	%% @todo Should probably send a 426 if the Upgrade header is missing.
	{ok, [<<"websocket">>], Req3}
		= cowboy_req:parse_header(<<"upgrade">>, Req2),
	{Version, Req4} = cowboy_req:header(<<"sec-websocket-version">>, Req3),
	IntVersion = list_to_integer(binary_to_list(Version)),
	true = (IntVersion =:= 7) orelse (IntVersion =:= 8)
		orelse (IntVersion =:= 13),
	{Key, Req5} = cowboy_req:header(<<"sec-websocket-key">>, Req4),
	false = Key =:= undefined,
	{ok, State#state{key=Key},
		cowboy_req:set_meta(websocket_version, IntVersion, Req5)}.

-spec handler_init(#state{}, Req)
	-> {ok, Req, cowboy_middleware:env()} | {error, 400, Req}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
handler_init(State=#state{env=Env, transport=Transport,
		handler=Handler, handler_opts=HandlerOpts}, Req) ->
	try Handler:websocket_init(Transport:name(), Req, HandlerOpts) of
		{ok, Req2, HandlerState} ->
			websocket_handshake(State, Req2, HandlerState);
		{ok, Req2, HandlerState, hibernate} ->
			websocket_handshake(State#state{hibernate=true},
				Req2, HandlerState);
		{ok, Req2, HandlerState, Timeout} ->
			websocket_handshake(State#state{timeout=Timeout},
				Req2, HandlerState);
		{ok, Req2, HandlerState, Timeout, hibernate} ->
			websocket_handshake(State#state{timeout=Timeout,
				hibernate=true}, Req2, HandlerState);
		{shutdown, Req2} ->
			cowboy_req:ensure_response(Req2, 400),
			{ok, Req2, [{result, closed}|Env]}
	catch Class:Reason ->
		error_logger:error_msg(
			"** Cowboy handler ~p terminating in ~p/~p~n"
			"   for the reason ~p:~p~n** Options were ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, websocket_init, 3, Class, Reason, HandlerOpts,
				cowboy_req:to_list(Req),erlang:get_stacktrace()]),
		upgrade_error(Req, Env)
	end.

-spec upgrade_error(Req, Env) -> {ok, Req, Env} | {error, 400, Req}
	when Req::cowboy_req:req(), Env::cowboy_middleware:env().
upgrade_error(Req, Env) ->
	receive
		{cowboy_req, resp_sent} ->
			{ok, Req, [{result, closed}|Env]}
	after 0 ->
		{error, 400, Req}
	end.

-spec websocket_handshake(#state{}, Req, any())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
websocket_handshake(State=#state{transport=Transport, key=Key},
		Req, HandlerState) ->
	Challenge = base64:encode(crypto:sha(
		<< Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" >>)),
	{ok, Req2} = cowboy_req:upgrade_reply(
		101,
		[{<<"upgrade">>, <<"websocket">>},
		 {<<"sec-websocket-accept">>, Challenge}],
		Req),
	%% Flush the resp_sent message before moving on.
	receive {cowboy_req, resp_sent} -> ok after 0 -> ok end,
	State2 = handler_loop_timeout(State),
	handler_before_loop(State2#state{key=undefined,
		messages=Transport:messages()}, Req2, HandlerState, <<>>).

-spec handler_before_loop(#state{}, Req, any(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
handler_before_loop(State=#state{
			socket=Socket, transport=Transport, hibernate=true},
		Req, HandlerState, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	{suspend, ?MODULE, handler_loop,
		[State#state{hibernate=false}, Req, HandlerState, SoFar]};
handler_before_loop(State=#state{socket=Socket, transport=Transport},
		Req, HandlerState, SoFar) ->
	Transport:setopts(Socket, [{active, once}]),
	handler_loop(State, Req, HandlerState, SoFar).

-spec handler_loop_timeout(#state{}) -> #state{}.
handler_loop_timeout(State=#state{timeout=infinity}) ->
	State#state{timeout_ref=undefined};
handler_loop_timeout(State=#state{timeout=Timeout, timeout_ref=PrevRef}) ->
	_ = case PrevRef of undefined -> ignore; PrevRef ->
		erlang:cancel_timer(PrevRef) end,
	TRef = erlang:start_timer(Timeout, self(), ?MODULE),
	State#state{timeout_ref=TRef}.

%% @private
-spec handler_loop(#state{}, Req, any(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
handler_loop(State=#state{
			socket=Socket, messages={OK, Closed, Error}, timeout_ref=TRef},
		Req, HandlerState, SoFar) ->
	receive
		{OK, Socket, Data} ->
			State2 = handler_loop_timeout(State),
			websocket_data(State2, Req, HandlerState,
				<< SoFar/binary, Data/binary >>);
		{Closed, Socket} ->
			handler_terminate(State, Req, HandlerState, {error, closed});
		{Error, Socket, Reason} ->
			handler_terminate(State, Req, HandlerState, {error, Reason});
		{timeout, TRef, ?MODULE} ->
			websocket_close(State, Req, HandlerState, {normal, timeout});
		{timeout, OlderTRef, ?MODULE} when is_reference(OlderTRef) ->
			handler_loop(State, Req, HandlerState, SoFar);
		Message ->
			handler_call(State, Req, HandlerState,
				SoFar, websocket_info, Message, fun handler_before_loop/4)
	end.

-spec websocket_data(#state{}, Req, any(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
%% No more data.
websocket_data(State, Req, HandlerState, <<>>) ->
	handler_before_loop(State, Req, HandlerState, <<>>);
%% Incomplete.
websocket_data(State, Req, HandlerState, Data) when byte_size(Data) =:= 1 ->
	handler_before_loop(State, Req, HandlerState, Data);
%% 7 bit payload length prefix exists
websocket_data(State, Req, HandlerState,
		<< Fin:1, Rsv:3, Opcode:4, 1:1, PayloadLen:7, Rest/bits >>
		= Data) when PayloadLen < 126 ->
	websocket_data(State, Req, HandlerState,
		Fin, Rsv, Opcode, PayloadLen, Rest, Data);
%% 7+16 bits payload length prefix exists
websocket_data(State, Req, HandlerState,
		<< Fin:1, Rsv:3, Opcode:4, 1:1, 126:7, PayloadLen:16, Rest/bits >>
		= Data) when PayloadLen > 125 ->
	websocket_data(State, Req, HandlerState,
		Fin, Rsv, Opcode, PayloadLen, Rest, Data);
%% 7+16 bits payload length prefix missing
websocket_data(State, Req, HandlerState,
		<< _Fin:1, _Rsv:3, _Opcode:4, 1:1, 126:7, Rest/bits >>
		= Data) when byte_size(Rest) < 2 ->
	handler_before_loop(State, Req, HandlerState, Data);
%% 7+64 bits payload length prefix exists
websocket_data(State, Req, HandlerState,
		<< Fin:1, Rsv:3, Opcode:4, 1:1, 127:7, 0:1, PayloadLen:63,
		   Rest/bits >> = Data) when PayloadLen > 16#FFFF ->
	websocket_data(State, Req, HandlerState,
		Fin, Rsv, Opcode, PayloadLen, Rest, Data);
%% 7+64 bits payload length prefix missing
websocket_data(State, Req, HandlerState,
		<< _Fin:1, _Rsv:3, _Opcode:4, 1:1, 127:7, Rest/bits >>
		= Data) when byte_size(Rest) < 8 ->
	handler_before_loop(State, Req, HandlerState, Data);
%% Invalid payload length or mask bit was not set.
websocket_data(State, Req, HandlerState, _Data) ->
	websocket_close(State, Req, HandlerState, {error, badframe}).

-spec websocket_data(#state{}, Req, any(), non_neg_integer(),
		non_neg_integer(), non_neg_integer(),
		non_neg_integer(), binary(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	when Req::cowboy_req:req().
%% A fragmented message MUST start a non-zero opcode.
websocket_data(State=#state{frag_state=undefined}, Req, HandlerState,
		_Fin=0, _Rsv=0, _Opcode=0, _PayloadLen, _Rest, _Buffer) ->
	websocket_close(State, Req, HandlerState, {error, badframe});
%% A control message MUST NOT be fragmented.
websocket_data(State, Req, HandlerState, _Fin=0, _Rsv=0, Opcode,
		_PayloadLen, _Rest, _Buffer) when Opcode >= 8 ->
	websocket_close(State, Req, HandlerState, {error, badframe});
%% The opcode is only included in the first message fragment.
websocket_data(State=#state{frag_state=undefined}, Req, HandlerState,
		_Fin=0, _Rsv=0, Opcode, PayloadLen, Rest, Data) ->
	websocket_before_unmask(
		State#state{frag_state={nofin, Opcode}}, Req, HandlerState,
		Data, Rest, 0, PayloadLen);
%% non-control opcode when expecting control message or next fragment.
websocket_data(State=#state{frag_state={nofin, _, _}}, Req, HandlerState, _Fin,
		_Rsv=0, Opcode, _Ln, _Rest, _Data) when Opcode > 0, Opcode < 8 ->
	websocket_close(State, Req, HandlerState, {error, badframe});
%% If the first message fragment was incomplete, retry unmasking.
websocket_data(State=#state{frag_state={nofin, Opcode}}, Req, HandlerState,
		_Fin=0, _Rsv=0, Opcode, PayloadLen, Rest, Data) ->
	websocket_before_unmask(
		State#state{frag_state={nofin, Opcode}}, Req, HandlerState,
		Data, Rest, 0, PayloadLen);
%% if the opcode is zero and the fin flag is zero, unmask and await next.
websocket_data(State=#state{frag_state={nofin, _Opcode, _Payloads}}, Req,
		HandlerState, _Fin=0, _Rsv=0, _Opcode2=0, PayloadLen, Rest,
		Data) ->
	websocket_before_unmask(
		State, Req, HandlerState, Data, Rest, 0, PayloadLen);
%% when the last fragment is seen. Update the fragmentation status.
websocket_data(State=#state{frag_state={nofin, Opcode, Payloads}}, Req,
		HandlerState, _Fin=1, _Rsv=0, _Opcode=0, PayloadLen, Rest,
		Data) ->
	websocket_before_unmask(
		State#state{frag_state={fin, Opcode, Payloads}},
		Req, HandlerState, Data, Rest, 0, PayloadLen);
%% control messages MUST NOT use 7+16 bits or 7+64 bits payload length prefixes
websocket_data(State, Req, HandlerState, _Fin, _Rsv, Opcode, PayloadLen,
		_Rest, _Data) when Opcode >= 8, PayloadLen > 125 ->
	 websocket_close(State, Req, HandlerState, {error, badframe});
%% unfragmented message. unmask and dispatch the message.
websocket_data(State, Req, HandlerState, _Fin=1, _Rsv=0,
		Opcode, PayloadLen, Rest, Data) ->
	websocket_before_unmask(
			State, Req, HandlerState, Data, Rest, Opcode, PayloadLen);
%% Something was wrong with the frame. Close the connection.
websocket_data(State, Req, HandlerState, _Fin, _Rsv, _Opcode,
		_PayloadLen, _Rest, _Data) ->
	websocket_close(State, Req, HandlerState, {error, badframe}).

%% Routing depending on whether unmasking is needed.
-spec websocket_before_unmask(#state{}, Req, any(), binary(),
	binary(), opcode(), non_neg_integer() | undefined)
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
websocket_before_unmask(State, Req, HandlerState, Data,
		Rest, Opcode, PayloadLen) ->
	case PayloadLen of
		N when N + 4 > byte_size(Rest); N =:= undefined ->
			%% @todo We probably should allow limiting frame length.
			handler_before_loop(State, Req, HandlerState, Data);
		_N ->
			<< MaskKey:32, Payload:PayloadLen/binary, Rest2/bits >> = Rest,
			websocket_unmask(State, Req, HandlerState, Rest2,
				Opcode, Payload, MaskKey)
	end.

%% Unmasking.
-spec websocket_unmask(#state{}, Req, any(), binary(),
	opcode(), binary(), mask_key())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, Payload, MaskKey) ->
	websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, Payload, MaskKey, <<>>).

-spec websocket_unmask(#state{}, Req, any(), binary(),
	opcode(), binary(), mask_key(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, << O:32, Rest/bits >>, MaskKey, Acc) ->
	T = O bxor MaskKey,
	websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, Rest, MaskKey, << Acc/binary, T:32 >>);
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, << O:24 >>, MaskKey, Acc) ->
	<< MaskKey2:24, _:8 >> = << MaskKey:32 >>,
	T = O bxor MaskKey2,
	websocket_dispatch(State, Req, HandlerState, RemainingData,
		Opcode, << Acc/binary, T:24 >>);
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, << O:16 >>, MaskKey, Acc) ->
	<< MaskKey2:16, _:16 >> = << MaskKey:32 >>,
	T = O bxor MaskKey2,
	websocket_dispatch(State, Req, HandlerState, RemainingData,
		Opcode, << Acc/binary, T:16 >>);
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, << O:8 >>, MaskKey, Acc) ->
	<< MaskKey2:8, _:24 >> = << MaskKey:32 >>,
	T = O bxor MaskKey2,
	websocket_dispatch(State, Req, HandlerState, RemainingData,
		Opcode, << Acc/binary, T:8 >>);
websocket_unmask(State, Req, HandlerState, RemainingData,
		Opcode, <<>>, _MaskKey, Acc) ->
	websocket_dispatch(State, Req, HandlerState, RemainingData,
		Opcode, Acc).

%% Dispatching.
-spec websocket_dispatch(#state{}, Req, any(), binary(), opcode(), binary())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
%% First frame of a fragmented message unmasked. Expect intermediate or last.
websocket_dispatch(State=#state{frag_state={nofin, Opcode}}, Req, HandlerState,
		RemainingData, 0, Payload) ->
	websocket_data(State#state{frag_state={nofin, Opcode, Payload}},
		Req, HandlerState, RemainingData);
%% Intermediate frame of a fragmented message unmasked. Add payload to buffer.
websocket_dispatch(State=#state{frag_state={nofin, Opcode, Payloads}}, Req,
		HandlerState, RemainingData, 0, Payload) ->
	websocket_data(State#state{frag_state={nofin, Opcode,
		<<Payloads/binary, Payload/binary>>}}, Req, HandlerState,
		RemainingData);
%% Last frame of a fragmented message unmasked. Dispatch to handler.
websocket_dispatch(State=#state{frag_state={fin, Opcode, Payloads}}, Req,
		HandlerState, RemainingData, 0, Payload) ->
	websocket_dispatch(State#state{frag_state=undefined}, Req, HandlerState,
		RemainingData, Opcode, <<Payloads/binary, Payload/binary>>);
%% Text frame.
websocket_dispatch(State, Req, HandlerState, RemainingData, 1, Payload) ->
	handler_call(State, Req, HandlerState, RemainingData,
		websocket_handle, {text, Payload}, fun websocket_data/4);
%% Binary frame.
websocket_dispatch(State, Req, HandlerState, RemainingData, 2, Payload) ->
	handler_call(State, Req, HandlerState, RemainingData,
		websocket_handle, {binary, Payload}, fun websocket_data/4);
%% Close control frame.
%% @todo Handle the optional Payload.
websocket_dispatch(State, Req, HandlerState, _RemainingData, 8, _Payload) ->
	websocket_close(State, Req, HandlerState, {normal, closed});
%% Ping control frame. Send a pong back and forward the ping to the handler.
websocket_dispatch(State=#state{socket=Socket, transport=Transport},
		Req, HandlerState, RemainingData, 9, Payload) ->
	Len = payload_length_to_binary(byte_size(Payload)),
	Transport:send(Socket, << 1:1, 0:3, 10:4, 0:1, Len/bits, Payload/binary >>),
	handler_call(State, Req, HandlerState, RemainingData,
		websocket_handle, {ping, Payload}, fun websocket_data/4);
%% Pong control frame.
websocket_dispatch(State, Req, HandlerState, RemainingData, 10, Payload) ->
	handler_call(State, Req, HandlerState, RemainingData,
		websocket_handle, {pong, Payload}, fun websocket_data/4).

-spec handler_call(#state{}, Req, any(), binary(), atom(), any(), fun())
	-> {ok, Req, cowboy_middleware:env()}
	| {suspend, module(), atom(), [any()]}
	when Req::cowboy_req:req().
handler_call(State=#state{handler=Handler, handler_opts=HandlerOpts}, Req,
		HandlerState, RemainingData, Callback, Message, NextState) ->
	try Handler:Callback(Message, Req, HandlerState) of
		{ok, Req2, HandlerState2} ->
			NextState(State, Req2, HandlerState2, RemainingData);
		{ok, Req2, HandlerState2, hibernate} ->
			NextState(State#state{hibernate=true},
				Req2, HandlerState2, RemainingData);
		{reply, Payload, Req2, HandlerState2}
				when is_tuple(Payload) ->
			case websocket_send(Payload, State) of
				ok ->
					State2 = handler_loop_timeout(State),	
					NextState(State2, Req2, HandlerState2, RemainingData);
				shutdown ->
					handler_terminate(State, Req2, HandlerState,
						{normal, shutdown});
				{error, _} = Error ->
					handler_terminate(State, Req2, HandlerState2, Error)
			end;
		{reply, Payload, Req2, HandlerState2, hibernate}
				when is_tuple(Payload) ->
			case websocket_send(Payload, State) of
				ok ->
					State2 = handler_loop_timeout(State),	
					NextState(State2#state{hibernate=true},
						Req2, HandlerState2, RemainingData);
				shutdown ->
					handler_terminate(State, Req2, HandlerState,
						{normal, shutdown});
				{error, _} = Error ->
					handler_terminate(State, Req2, HandlerState2, Error)
			end;
		{reply, Payload, Req2, HandlerState2}
				when is_list(Payload) ->
			case websocket_send_many(Payload, State) of
				ok ->
					State2 = handler_loop_timeout(State),	
					NextState(State2, Req2, HandlerState2, RemainingData);
				shutdown ->
					handler_terminate(State, Req2, HandlerState,
						{normal, shutdown});
				{error, _} = Error ->
					handler_terminate(State, Req2, HandlerState2, Error)
			end;
		{reply, Payload, Req2, HandlerState2, hibernate}
				when is_list(Payload) ->
			case websocket_send_many(Payload, State) of
				ok ->
					State2 = handler_loop_timeout(State),	
					NextState(State2#state{hibernate=true},
						Req2, HandlerState2, RemainingData);
				shutdown ->
					handler_terminate(State, Req2, HandlerState,
						{normal, shutdown});
				{error, _} = Error ->
					handler_terminate(State, Req2, HandlerState2, Error)
			end;
		{shutdown, Req2, HandlerState2} ->
			websocket_close(State, Req2, HandlerState2, {normal, shutdown})
	catch Class:Reason ->
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Cowboy handler ~p terminating in ~p/~p~n"
			"   for the reason ~p:~p~n** Message was ~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, Callback, 3, Class, Reason, Message, HandlerOpts,
			 HandlerState, PLReq, erlang:get_stacktrace()]),
		websocket_close(State, Req, HandlerState, {error, handler})
	end.

websocket_opcode(text) -> 1;
websocket_opcode(binary) -> 2;
websocket_opcode(close) -> 8;
websocket_opcode(ping) -> 9;
websocket_opcode(pong) -> 10.

-spec websocket_send(frame(), #state{})
	-> ok | shutdown | {error, atom()}.
websocket_send(Type, #state{socket=Socket, transport=Transport})
		when Type =:= close ->
	Opcode = websocket_opcode(Type),
	case Transport:send(Socket, << 1:1, 0:3, Opcode:4, 0:8 >>) of
		ok -> shutdown;
		Error -> Error
	end;
websocket_send(Type, #state{socket=Socket, transport=Transport})
		when Type =:= ping; Type =:= pong ->
	Opcode = websocket_opcode(Type),
	Transport:send(Socket, << 1:1, 0:3, Opcode:4, 0:8 >>);
websocket_send({close, Payload}, State) ->
	websocket_send({close, 1000, Payload}, State);
websocket_send({Type = close, StatusCode, Payload}, #state{
		socket=Socket, transport=Transport}) ->
	Opcode = websocket_opcode(Type),
	Len = 2 + iolist_size(Payload),
	%% Control packets must not be > 125 in length.
	true = Len =< 125,
	BinLen = payload_length_to_binary(Len),
	Transport:send(Socket,
		[<< 1:1, 0:3, Opcode:4, 0:1, BinLen/bits, StatusCode:16 >>, Payload]),
	shutdown;
websocket_send({Type, Payload}, #state{socket=Socket, transport=Transport}) ->
	Opcode = websocket_opcode(Type),
	Len = iolist_size(Payload),
	%% Control packets must not be > 125 in length.
	true = if Type =:= ping; Type =:= pong ->
			Len =< 125;
		true ->
			true
	end,
	BinLen = payload_length_to_binary(Len),
	Transport:send(Socket,
		[<< 1:1, 0:3, Opcode:4, 0:1, BinLen/bits >>, Payload]).

-spec websocket_send_many([frame()], #state{})
	-> ok | shutdown | {error, atom()}.
websocket_send_many([], _) ->
	ok;
websocket_send_many([Frame|Tail], State) ->
	case websocket_send(Frame, State) of
		ok -> websocket_send_many(Tail, State);
		shutdown -> shutdown;
		Error -> Error
	end.

-spec websocket_close(#state{}, Req, any(), {atom(), atom()})
	-> {ok, Req, cowboy_middleware:env()}
	when Req::cowboy_req:req().
websocket_close(State=#state{socket=Socket, transport=Transport},
		Req, HandlerState, Reason) ->
	Transport:send(Socket, << 1:1, 0:3, 8:4, 0:8 >>),
	handler_terminate(State, Req, HandlerState, Reason).

-spec handler_terminate(#state{}, Req, any(), atom() | {atom(), atom()})
	-> {ok, Req, cowboy_middleware:env()}
	when Req::cowboy_req:req().
handler_terminate(#state{env=Env, handler=Handler, handler_opts=HandlerOpts},
		Req, HandlerState, TerminateReason) ->
	try
		Handler:websocket_terminate(TerminateReason, Req, HandlerState)
	catch Class:Reason ->
		PLReq = cowboy_req:to_list(Req),
		error_logger:error_msg(
			"** Cowboy handler ~p terminating in ~p/~p~n"
			"   for the reason ~p:~p~n** Initial reason was ~p~n"
			"** Options were ~p~n** Handler state was ~p~n"
			"** Request was ~p~n** Stacktrace: ~p~n~n",
			[Handler, websocket_terminate, 3, Class, Reason, TerminateReason,
				HandlerOpts, HandlerState, PLReq, erlang:get_stacktrace()])
	end,
	{ok, Req, [{result, closed}|Env]}.

-spec payload_length_to_binary(0..16#7fffffffffffffff)
	-> << _:7 >> | << _:23 >> | << _:71 >>.
payload_length_to_binary(N) ->
	case N of
		N when N =< 125 -> << N:7 >>;
		N when N =< 16#ffff -> << 126:7, N:16 >>;
		N when N =< 16#7fffffffffffffff -> << 127:7, N:64 >>
	end.
