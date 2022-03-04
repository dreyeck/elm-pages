module Page.CookieTest exposing (Data, Model, Msg, page)

import DataSource exposing (DataSource)
import Head
import Head.Seo as Seo
import Html.Styled exposing (text)
import Page exposing (Page, PageWithState, StaticPayload)
import Pages.PageUrl exposing (PageUrl)
import Pages.Url
import Server.Request as Request exposing (Request)
import Server.Response as Response exposing (Response)
import Shared
import View exposing (View)


type alias Model =
    {}


type alias Msg =
    ()


type alias RouteParams =
    {}


page : Page RouteParams Data
page =
    Page.serverRender
        { head = head
        , data = data
        }
        |> Page.buildNoState { view = view }


type alias Data =
    { darkMode : Maybe String }


data : RouteParams -> Request (DataSource (Response Data))
data routeParams =
    Request.oneOf
        [ Request.expectCookie "dark-mode"
            |> Request.map
                (\darkMode ->
                    DataSource.succeed (Response.render { darkMode = Just darkMode })
                )
        , Request.succeed
            (DataSource.succeed (Response.render { darkMode = Nothing }))
        ]


head :
    StaticPayload Data RouteParams
    -> List Head.Tag
head static =
    []


view :
    Maybe PageUrl
    -> Shared.Model
    -> StaticPayload Data RouteParams
    -> View Msg
view maybeUrl sharedModel static =
    { title = "Cookie test"
    , body =
        [ case static.data.darkMode of
            Just darkMode ->
                text <|
                    "Dark mode: "
                        ++ darkMode

            Nothing ->
                text "No dark mode preference set"
        ]
    }
