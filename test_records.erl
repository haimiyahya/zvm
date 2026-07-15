-module(test_records).
-export([create_person/2, get_age/1, update_city/2]).

-record(person, {name, age, city}).

create_person(Name, Age) ->
    #person{name = Name, age = Age, city = "Unknown"}.

get_age(#person{age = Age}) -> Age.

update_city(Person, NewCity) ->
    Person#person{city = NewCity}.