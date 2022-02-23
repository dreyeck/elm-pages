module MySession exposing (..)

import Codec
import DataSource exposing (DataSource)
import DataSource.Env as Env
import Dict
import Server.Request exposing (Request)
import Server.Response as Response exposing (Response)
import Server.Session as Session


withSession :
    Request request
    -> (request -> Result () (Maybe Session.Session) -> DataSource ( Session.Session, Response data ))
    -> Request (DataSource (Response data))
withSession =
    Session.withSession
        { name = "mysession"
        , secrets = Env.expect "SESSION_SECRET" |> DataSource.map List.singleton
        , sameSite = "lax"
        }


withSessionOrRedirect :
    Request request
    -> (request -> Maybe Session.Session -> DataSource ( Session.Session, Response data ))
    -> Request (DataSource (Response data))
withSessionOrRedirect handler toRequest =
    Session.withSession
        { name = "mysession"
        , secrets = Env.expect "SESSION_SECRET" |> DataSource.map List.singleton
        , sameSite = "lax"
        }
        handler
        (\request sessionResult ->
            sessionResult
                |> Result.map (toRequest request)
                |> Result.withDefault
                    (DataSource.succeed
                        ( Session.empty
                        , Response.temporaryRedirect "/login"
                        )
                    )
        )


expectSessionOrRedirect :
    (request -> Session.Session -> DataSource ( Session.Session, Response data ))
    -> Request request
    -> Request (DataSource (Response data))
expectSessionOrRedirect toRequest handler =
    Session.withSession
        { name = "mysession"
        , secrets = Env.expect "SESSION_SECRET" |> DataSource.map List.singleton
        , sameSite = "lax"
        }
        handler
        (\request sessionResult ->
            sessionResult
                |> Result.map (Maybe.map (toRequest request))
                |> Result.withDefault Nothing
                |> Maybe.withDefault
                    (DataSource.succeed
                        ( Session.empty
                        , Response.temporaryRedirect "/login"
                        )
                    )
        )


schema =
    { name = ( "name", Codec.string )
    , message = ( "message", Codec.string )
    , user =
        ( "user"
        , Codec.object User
            |> Codec.field "id" .id Codec.int
            |> Codec.buildObject
        )
    }


type alias User =
    { id : Int
    }


schemaUpdate getter value =
    let
        ( name, codec ) =
            schema |> getter
    in
    Session.oneUpdate name ((codec |> Codec.encodeToString 1) value)


schemaGet getter sessionDict =
    let
        ( name, codec ) =
            schema |> getter
    in
    sessionDict
        |> Dict.get name
        |> Maybe.map (codec |> Codec.decodeString)


exampleSchemaUpdate =
    schemaUpdate .name "John Doe"


exampleSchemaGet =
    schemaGet .name


exampleUpdate =
    Session.oneUpdate "name" "NAME"



--|> Session.withFlash "message" ("Welcome " ++ name ++ "!")
