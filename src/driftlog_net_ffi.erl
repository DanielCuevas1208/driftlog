%% Driftlog networking FFI.
%%
%% A thin wrapper around Erlang/OTP's `gen_tcp`. The Gleam layer (`driftlog/sync/net`)
%% keeps every socket in an opaque type and calls these functions through
%% `@external`. No socket leaves this module.
%%
%% Sockets run in passive mode. `recv/1` reads all bytes that are currently
%% available, which lets the Gleam layer frame the newline-delimited JSON
%% protocol without holding a buffer open forever.

-module(driftlog_net_ffi).

-export([
    listen/1,
    accept/1,
    connect/2,
    send/2,
    recv/1,
    close/1,
    port/1,
    read_file/1,
    argv/0
]).

listen(Port) ->
    Options = [binary, {packet, raw}, {active, false}, {reuseaddr, true}],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

connect(Host, Port) ->
    Options = [binary, {packet, raw}, {active, false}],
    case gen_tcp:connect(host_address(Host), Port, Options) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, byte_size(Data)};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

recv(Socket) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Data} -> {ok, Data};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

close(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.

port(Socket) ->
    case inet:sockname(Socket) of
        {ok, {_Address, Port}} -> Port;
        {error, Reason} -> erlang:error(Reason)
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Binary} -> {ok, Binary};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

argv() ->
    [to_utf8(Argument) || Argument <- init:get_plain_arguments()].

to_utf8(Argument) when is_binary(Argument) ->
    Argument;
to_utf8(Argument) when is_list(Argument) ->
    unicode:characters_to_binary(Argument).

to_charlist(Host) when is_binary(Host) ->
    binary_to_list(Host);
to_charlist(Host) when is_list(Host) ->
    Host.

host_address(Host) ->
    HostChars = to_charlist(Host),
    case inet:parse_address(HostChars) of
        {ok, Address} -> Address;
        {error, _} -> HostChars
    end.

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
