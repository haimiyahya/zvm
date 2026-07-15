-module(test_complex).
-export([factorial/1, fibonacci/1, process_list/1, pattern_match/1]).
-export([complex_function/3]).

factorial(0) -> 1;
factorial(N) when N > 0 -> N * factorial(N - 1).

fibonacci(0) -> 0;
fibonacci(1) -> 1;
fibonacci(N) when N > 1 -> fibonacci(N - 1) + fibonacci(N - 2).

process_list([]) -> [];
process_list([H|T]) -> [H * 2 | process_list(T)].

pattern_match({ok, Value}) -> Value;
pattern_match({error, Reason}) -> {error, Reason};
pattern_match(Other) -> Other.

complex_function(A, B, C) when A > B ->
    case C of
        true -> A + B;
        false -> A - B
    end;
complex_function(A, B, C) when A < B ->
    case C of
        true -> B - A;
        false -> B + A
    end;
complex_function(A, B, _C) ->
    A * B.