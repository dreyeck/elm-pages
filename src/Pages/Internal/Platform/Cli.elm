module Pages.Internal.Platform.Cli exposing (Flags, Model, Msg(..), Program, cliApplication, init, requestDecoder, update, currentCompatibilityKey)

{-| Exposed for internal use only (used in generated code).

@docs Flags, Model, Msg, Program, cliApplication, init, requestDecoder, update, currentCompatibilityKey

-}

import BuildError exposing (BuildError)
import Bytes exposing (Bytes)
import Bytes.Encode
import Codec
import DataSource exposing (DataSource)
import Dict
import Head exposing (Tag)
import Html exposing (Html)
import HtmlPrinter
import Internal.ApiRoute exposing (ApiRoute(..))
import Json.Decode as Decode
import Json.Encode
import PageServerResponse exposing (PageServerResponse)
import Pages.Flags
import Pages.Internal.NotFoundReason as NotFoundReason exposing (NotFoundReason)
import Pages.Internal.Platform.CompatibilityKey
import Pages.Internal.Platform.Effect as Effect exposing (Effect)
import Pages.Internal.Platform.StaticResponses as StaticResponses exposing (StaticResponses)
import Pages.Internal.Platform.ToJsPayload as ToJsPayload
import Pages.Internal.ResponseSketch as ResponseSketch
import Pages.Msg
import Pages.ProgramConfig exposing (ProgramConfig)
import Pages.SiteConfig exposing (SiteConfig)
import Pages.StaticHttp.Request
import Path exposing (Path)
import RenderRequest exposing (IncludeHtml(..), RenderRequest)
import RequestsAndPending exposing (RequestsAndPending)
import TerminalText as Terminal
import Url exposing (Url)


{-| -}
type alias Flags =
    Decode.Value


{-| -}
currentCompatibilityKey : Int
currentCompatibilityKey =
    Pages.Internal.Platform.CompatibilityKey.currentCompatibilityKey


{-| -}
type alias Model route =
    { staticResponses : StaticResponses Effect
    , errors : List BuildError
    , allRawResponses : RequestsAndPending
    , maybeRequestJson : RenderRequest route
    , isDevServer : Bool
    }


{-| -}
type Msg
    = GotDataBatch
        (List
            { request : Pages.StaticHttp.Request.Request
            , response : RequestsAndPending.Response
            }
        )
    | GotBuildError BuildError


{-| -}
type alias Program route =
    Platform.Program Flags (Model route) Msg


{-| -}
cliApplication :
    ProgramConfig userMsg userModel (Maybe route) pageData actionData sharedData effect mappedMsg errorPage
    -> Program (Maybe route)
cliApplication config =
    let
        site : SiteConfig
        site =
            getSiteConfig config

        getSiteConfig : ProgramConfig userMsg userModel (Maybe route) pageData actionData sharedData effect mappedMsg errorPage -> SiteConfig
        getSiteConfig fullConfig =
            case fullConfig.site of
                Just mySite ->
                    mySite

                Nothing ->
                    getSiteConfig fullConfig
    in
    Platform.worker
        { init =
            \flags ->
                let
                    renderRequest : RenderRequest (Maybe route)
                    renderRequest =
                        Decode.decodeValue (RenderRequest.decoder config) flags
                            |> Result.withDefault RenderRequest.default
                in
                init site renderRequest config flags
                    |> Tuple.mapSecond (perform site renderRequest config)
        , update =
            \msg model ->
                update site config msg model
                    |> Tuple.mapSecond (perform site model.maybeRequestJson config)
        , subscriptions =
            \_ ->
                Sub.batch
                    [ config.fromJsPort
                        |> Sub.map
                            (\jsonValue ->
                                let
                                    decoder : Decode.Decoder Msg
                                    decoder =
                                        Decode.field "tag" Decode.string
                                            |> Decode.andThen
                                                (\tag ->
                                                    case tag of
                                                        "BuildError" ->
                                                            Decode.field "data"
                                                                (Decode.map2
                                                                    (\message title ->
                                                                        { title = title
                                                                        , message = message
                                                                        , fatal = True
                                                                        , path = "" -- TODO wire in current path here
                                                                        }
                                                                    )
                                                                    (Decode.field "message" Decode.string |> Decode.map Terminal.fromAnsiString)
                                                                    (Decode.field "title" Decode.string)
                                                                )
                                                                |> Decode.map GotBuildError

                                                        _ ->
                                                            Decode.fail "Unhandled msg"
                                                )
                                in
                                Decode.decodeValue decoder jsonValue
                                    |> Result.mapError
                                        (\error ->
                                            ("From location 1: "
                                                ++ (error
                                                        |> Decode.errorToString
                                                   )
                                            )
                                                |> BuildError.internal
                                                |> GotBuildError
                                        )
                                    |> mergeResult
                            )
                    , config.gotBatchSub
                        |> Sub.map
                            (\newBatch ->
                                Decode.decodeValue batchDecoder newBatch
                                    |> Result.map GotDataBatch
                                    |> Result.mapError
                                        (\error ->
                                            ("From location 2: "
                                                ++ (error
                                                        |> Decode.errorToString
                                                   )
                                            )
                                                |> BuildError.internal
                                                |> GotBuildError
                                        )
                                    |> mergeResult
                            )
                    ]
        }


batchDecoder : Decode.Decoder (List { request : Pages.StaticHttp.Request.Request, response : RequestsAndPending.Response })
batchDecoder =
    Decode.map2 (\request response -> { request = request, response = response })
        (Decode.field "request" requestDecoder)
        (Decode.field "response" RequestsAndPending.decoder)
        |> Decode.list


mergeResult : Result a a -> a
mergeResult r =
    case r of
        Ok rr ->
            rr

        Err rr ->
            rr


{-| -}
requestDecoder : Decode.Decoder Pages.StaticHttp.Request.Request
requestDecoder =
    Pages.StaticHttp.Request.codec
        |> Codec.decoder


flatten : SiteConfig -> RenderRequest route -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage -> List Effect -> Cmd Msg
flatten site renderRequest config list =
    Cmd.batch (flattenHelp [] site renderRequest config list)


flattenHelp : List (Cmd Msg) -> SiteConfig -> RenderRequest route -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage -> List Effect -> List (Cmd Msg)
flattenHelp soFar site renderRequest config list =
    case list of
        first :: rest ->
            flattenHelp
                (perform site renderRequest config first :: soFar)
                site
                renderRequest
                config
                rest

        [] ->
            soFar


perform :
    SiteConfig
    -> RenderRequest route
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Effect
    -> Cmd Msg
perform site renderRequest config effect =
    let
        canonicalSiteUrl : String
        canonicalSiteUrl =
            site.canonicalUrl
    in
    case effect of
        Effect.NoEffect ->
            Cmd.none

        Effect.Batch list ->
            flatten site renderRequest config list

        Effect.FetchHttp unmasked ->
            ToJsPayload.DoHttp unmasked unmasked.useCache
                |> Codec.encoder (ToJsPayload.successCodecNew2 canonicalSiteUrl "")
                |> config.toJsPort
                |> Cmd.map never

        Effect.SendSinglePage info ->
            let
                currentPagePath : String
                currentPagePath =
                    case info of
                        ToJsPayload.PageProgress toJsSuccessPayloadNew ->
                            toJsSuccessPayloadNew.route

                        _ ->
                            ""
            in
            info
                |> Codec.encoder (ToJsPayload.successCodecNew2 canonicalSiteUrl currentPagePath)
                |> config.toJsPort
                |> Cmd.map never

        Effect.SendSinglePageNew rawBytes info ->
            let
                currentPagePath : String
                currentPagePath =
                    case info of
                        ToJsPayload.PageProgress toJsSuccessPayloadNew ->
                            toJsSuccessPayloadNew.route

                        _ ->
                            ""
            in
            { oldThing =
                info
                    |> Codec.encoder (ToJsPayload.successCodecNew2 canonicalSiteUrl currentPagePath)
            , binaryPageData = rawBytes
            }
                |> config.sendPageData
                |> Cmd.map never

        Effect.Continue ->
            Cmd.none


flagsDecoder :
    Decode.Decoder
        { staticHttpCache : RequestsAndPending
        , isDevServer : Bool
        , compatibilityKey : Int
        }
flagsDecoder =
    Decode.map3
        (\staticHttpCache isDevServer compatibilityKey ->
            { staticHttpCache = staticHttpCache
            , isDevServer = isDevServer
            , compatibilityKey = compatibilityKey
            }
        )
        --(Decode.field "staticHttpCache"
        --    (Decode.dict
        --        (Decode.string
        --            |> Decode.map Just
        --        )
        --    )
        --)
        -- TODO remove hardcoding and decode staticHttpCache here
        (Decode.succeed Dict.empty)
        (Decode.field "mode" Decode.string |> Decode.map (\mode -> mode == "dev-server"))
        (Decode.field "compatibilityKey" Decode.int)


{-| -}
init :
    SiteConfig
    -> RenderRequest route
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Decode.Value
    -> ( Model route, Effect )
init site renderRequest config flags =
    case Decode.decodeValue flagsDecoder flags of
        Ok { staticHttpCache, isDevServer, compatibilityKey } ->
            if compatibilityKey == currentCompatibilityKey then
                initLegacy site renderRequest { staticHttpCache = staticHttpCache, isDevServer = isDevServer } config

            else
                let
                    elmPackageAheadOfNpmPackage : Bool
                    elmPackageAheadOfNpmPackage =
                        currentCompatibilityKey > compatibilityKey

                    message : String
                    message =
                        "The NPM package and Elm package you have installed are incompatible. If you are updating versions, be sure to update both the elm-pages Elm and NPM package.\n\n"
                            ++ (if elmPackageAheadOfNpmPackage then
                                    "The elm-pages Elm package is ahead of the elm-pages NPM package. Try updating the elm-pages NPM package?"

                                else
                                    "The elm-pages NPM package is ahead of the elm-pages Elm package. Try updating the elm-pages Elm package?"
                               )
                in
                updateAndSendPortIfDone
                    site
                    config
                    { staticResponses = StaticResponses.empty Effect.NoEffect
                    , errors =
                        [ { title = "Incompatible NPM and Elm package versions"
                          , message = [ Terminal.text <| message ]
                          , fatal = True
                          , path = ""
                          }
                        ]
                    , allRawResponses = Dict.empty
                    , maybeRequestJson = renderRequest
                    , isDevServer = False
                    }

        Err error ->
            updateAndSendPortIfDone
                site
                config
                { staticResponses = StaticResponses.empty Effect.NoEffect
                , errors =
                    [ { title = "Internal Error"
                      , message = [ Terminal.text <| "Failed to parse flags: " ++ Decode.errorToString error ]
                      , fatal = True
                      , path = ""
                      }
                    ]
                , allRawResponses = Dict.empty
                , maybeRequestJson = renderRequest
                , isDevServer = False
                }


type ActionRequest
    = ActionResponseRequest
    | ActionOnlyRequest


isActionDecoder : Decode.Decoder (Maybe ActionRequest)
isActionDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "method" Decode.string)
        (Decode.field "headers" (Decode.dict Decode.string))
        |> Decode.map
            (\( method, headers ) ->
                case method |> String.toUpper of
                    "GET" ->
                        Nothing

                    "OPTIONS" ->
                        Nothing

                    _ ->
                        let
                            actionOnly : Bool
                            actionOnly =
                                case headers |> Dict.get "elm-pages-action-only" of
                                    Just _ ->
                                        True

                                    Nothing ->
                                        False
                        in
                        Just
                            (if actionOnly then
                                ActionOnlyRequest

                             else
                                ActionResponseRequest
                            )
            )


initLegacy :
    SiteConfig
    -> RenderRequest route
    -> { staticHttpCache : RequestsAndPending, isDevServer : Bool }
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> ( Model route, Effect )
initLegacy site ((RenderRequest.SinglePage includeHtml singleRequest _) as renderRequest) { staticHttpCache, isDevServer } config =
    let
        globalHeadTags : DataSource (List Tag)
        globalHeadTags =
            (config.globalHeadTags |> Maybe.withDefault (\_ -> DataSource.succeed [])) HtmlPrinter.htmlToString

        staticResponsesNew : StaticResponses Effect
        staticResponsesNew =
            StaticResponses.renderApiRequest
                (case singleRequest of
                    RenderRequest.Page serverRequestPayload ->
                        let
                            isAction : Maybe ActionRequest
                            isAction =
                                renderRequest
                                    |> RenderRequest.maybeRequestPayload
                                    |> Maybe.andThen (Decode.decodeValue isActionDecoder >> Result.withDefault Nothing)

                            currentUrl : Url
                            currentUrl =
                                { protocol = Url.Https
                                , host = site.canonicalUrl
                                , port_ = Nothing
                                , path = serverRequestPayload.path |> Path.toRelative
                                , query = Nothing
                                , fragment = Nothing
                                }
                        in
                        --case isAction of
                        --    Just actionRequest ->
                        (if isDevServer then
                            config.handleRoute serverRequestPayload.frontmatter

                         else
                            DataSource.succeed Nothing
                        )
                            |> DataSource.andThen
                                (\pageFound ->
                                    case pageFound of
                                        Nothing ->
                                            --sendSinglePageProgress site model.allRawResponses config model payload
                                            (case isAction of
                                                Just actionRequest ->
                                                    config.action (RenderRequest.maybeRequestPayload renderRequest |> Maybe.withDefault Json.Encode.null) serverRequestPayload.frontmatter |> DataSource.map Just

                                                Nothing ->
                                                    DataSource.succeed Nothing
                                            )
                                                |> DataSource.andThen
                                                    (\something ->
                                                        let
                                                            actionHeaders2 =
                                                                case something of
                                                                    Just (PageServerResponse.RenderPage responseThing actionThing) ->
                                                                        Just responseThing

                                                                    Just (PageServerResponse.ServerResponse responseThing) ->
                                                                        Just
                                                                            { headers = responseThing.headers
                                                                            , statusCode = responseThing.statusCode
                                                                            }

                                                                    _ ->
                                                                        Nothing
                                                        in
                                                        DataSource.map3
                                                            (\pageData sharedData tags ->
                                                                let
                                                                    renderedResult : Effect
                                                                    renderedResult =
                                                                        case pageData of
                                                                            PageServerResponse.RenderPage responseInfo pageData_ ->
                                                                                let
                                                                                    currentPage : { path : Path, route : route }
                                                                                    currentPage =
                                                                                        { path = serverRequestPayload.path, route = urlToRoute config currentUrl }

                                                                                    maybeActionData : Maybe actionData
                                                                                    maybeActionData =
                                                                                        case something of
                                                                                            Just (PageServerResponse.RenderPage responseThing actionThing) ->
                                                                                                Just actionThing

                                                                                            _ ->
                                                                                                Nothing

                                                                                    pageModel : userModel
                                                                                    pageModel =
                                                                                        config.init
                                                                                            Pages.Flags.PreRenderFlags
                                                                                            sharedData
                                                                                            pageData_
                                                                                            maybeActionData
                                                                                            (Just
                                                                                                { path =
                                                                                                    { path = currentPage.path
                                                                                                    , query = Nothing
                                                                                                    , fragment = Nothing
                                                                                                    }
                                                                                                , metadata = currentPage.route
                                                                                                , pageUrl = Nothing
                                                                                                }
                                                                                            )
                                                                                            |> Tuple.first

                                                                                    viewValue : { title : String, body : List (Html (Pages.Msg.Msg userMsg)) }
                                                                                    viewValue =
                                                                                        (config.view Dict.empty Dict.empty Nothing currentPage Nothing sharedData pageData_ maybeActionData |> .view) pageModel

                                                                                    responseMetadata : { statusCode : Int, headers : List ( String, String ) }
                                                                                    responseMetadata =
                                                                                        actionHeaders2 |> Maybe.withDefault responseInfo
                                                                                in
                                                                                (case isAction of
                                                                                    Just actionRequestKind ->
                                                                                        let
                                                                                            actionDataResult : Maybe (PageServerResponse actionData errorPage)
                                                                                            actionDataResult =
                                                                                                something
                                                                                        in
                                                                                        case actionDataResult of
                                                                                            Just (PageServerResponse.RenderPage ignored2 actionData_) ->
                                                                                                case actionRequestKind of
                                                                                                    ActionResponseRequest ->
                                                                                                        ( ignored2.headers
                                                                                                        , ResponseSketch.HotUpdate pageData_ sharedData (Just actionData_)
                                                                                                            |> config.encodeResponse
                                                                                                            |> Bytes.Encode.encode
                                                                                                        )

                                                                                                    ActionOnlyRequest ->
                                                                                                        ---- TODO need to encode action data when only that is requested (not ResponseSketch?)
                                                                                                        ( ignored2.headers
                                                                                                        , actionData_
                                                                                                            |> config.encodeAction
                                                                                                            |> Bytes.Encode.encode
                                                                                                        )

                                                                                            _ ->
                                                                                                ( responseMetadata.headers
                                                                                                , Bytes.Encode.encode (Bytes.Encode.unsignedInt8 0)
                                                                                                )

                                                                                    Nothing ->
                                                                                        ( responseMetadata.headers
                                                                                        , ResponseSketch.HotUpdate pageData_ sharedData Nothing
                                                                                            |> config.encodeResponse
                                                                                            |> Bytes.Encode.encode
                                                                                        )
                                                                                )
                                                                                    |> (\( actionHeaders, byteEncodedPageData ) ->
                                                                                            let
                                                                                                rendered =
                                                                                                    config.view Dict.empty Dict.empty Nothing currentPage Nothing sharedData pageData_ maybeActionData
                                                                                            in
                                                                                            PageServerResponse.toRedirect responseMetadata
                                                                                                |> Maybe.map
                                                                                                    (\{ location } ->
                                                                                                        location
                                                                                                            |> ResponseSketch.Redirect
                                                                                                            |> config.encodeResponse
                                                                                                            |> Bytes.Encode.encode
                                                                                                    )
                                                                                                -- TODO handle other cases besides redirects?
                                                                                                |> Maybe.withDefault byteEncodedPageData
                                                                                                |> (\encodedData ->
                                                                                                        { route = currentPage.path |> Path.toRelative
                                                                                                        , contentJson = Dict.empty
                                                                                                        , html = viewValue.body |> bodyToString
                                                                                                        , errors = []
                                                                                                        , head = rendered.head ++ tags
                                                                                                        , title = viewValue.title
                                                                                                        , staticHttpCache = Dict.empty
                                                                                                        , is404 = False
                                                                                                        , statusCode =
                                                                                                            case includeHtml of
                                                                                                                RenderRequest.OnlyJson ->
                                                                                                                    200

                                                                                                                RenderRequest.HtmlAndJson ->
                                                                                                                    responseMetadata.statusCode
                                                                                                        , headers =
                                                                                                            -- TODO should `responseInfo.headers` be used? Is there a problem in the case where there is both an action and data response in one? Do we need to make sure it is performed as two separate HTTP requests to ensure that the cookies are set correctly in that case?
                                                                                                            actionHeaders
                                                                                                        }
                                                                                                            |> ToJsPayload.PageProgress
                                                                                                            |> Effect.SendSinglePageNew encodedData
                                                                                                   )
                                                                                       )

                                                                            PageServerResponse.ServerResponse serverResponse ->
                                                                                --PageServerResponse.ServerResponse serverResponse
                                                                                -- TODO handle error?
                                                                                let
                                                                                    ( actionHeaders, byteEncodedPageData ) =
                                                                                        ( serverResponse.headers
                                                                                          --ignored1.headers
                                                                                        , PageServerResponse.toRedirect serverResponse
                                                                                            |> Maybe.map
                                                                                                (\{ location } ->
                                                                                                    location
                                                                                                        |> ResponseSketch.Redirect
                                                                                                        |> config.encodeResponse
                                                                                                )
                                                                                            -- TODO handle other cases besides redirects?
                                                                                            |> Maybe.withDefault (Bytes.Encode.unsignedInt8 0)
                                                                                            |> Bytes.Encode.encode
                                                                                        )

                                                                                    responseMetadata : PageServerResponse.Response
                                                                                    responseMetadata =
                                                                                        case something of
                                                                                            Just (PageServerResponse.ServerResponse responseThing) ->
                                                                                                responseThing

                                                                                            _ ->
                                                                                                serverResponse
                                                                                in
                                                                                PageServerResponse.toRedirect responseMetadata
                                                                                    |> Maybe.map
                                                                                        (\_ ->
                                                                                            { route = serverRequestPayload.path |> Path.toRelative
                                                                                            , contentJson = Dict.empty
                                                                                            , html = "This is intentionally blank HTML"
                                                                                            , errors = []
                                                                                            , head = []
                                                                                            , title = "This is an intentionally blank title"
                                                                                            , staticHttpCache = Dict.empty
                                                                                            , is404 = False
                                                                                            , statusCode =
                                                                                                case includeHtml of
                                                                                                    RenderRequest.OnlyJson ->
                                                                                                        -- if this is a redirect for a `content.dat`, we don't want to send an *actual* redirect status code because the redirect needs to be handled in Elm (not by the Browser)
                                                                                                        200

                                                                                                    RenderRequest.HtmlAndJson ->
                                                                                                        responseMetadata.statusCode
                                                                                            , headers = responseMetadata.headers --serverResponse.headers
                                                                                            }
                                                                                                |> ToJsPayload.PageProgress
                                                                                                |> Effect.SendSinglePageNew byteEncodedPageData
                                                                                        )
                                                                                    |> Maybe.withDefault
                                                                                        ({ body = serverResponse |> PageServerResponse.toJson
                                                                                         , staticHttpCache = Dict.empty
                                                                                         , statusCode = serverResponse.statusCode
                                                                                         }
                                                                                            |> ToJsPayload.SendApiResponse
                                                                                            |> Effect.SendSinglePage
                                                                                        )

                                                                            PageServerResponse.ErrorPage error record ->
                                                                                let
                                                                                    currentPage : { path : Path, route : route }
                                                                                    currentPage =
                                                                                        { path = serverRequestPayload.path, route = urlToRoute config currentUrl }

                                                                                    pageModel : userModel
                                                                                    pageModel =
                                                                                        config.init
                                                                                            Pages.Flags.PreRenderFlags
                                                                                            sharedData
                                                                                            pageData2
                                                                                            Nothing
                                                                                            (Just
                                                                                                { path =
                                                                                                    { path = currentPage.path
                                                                                                    , query = Nothing
                                                                                                    , fragment = Nothing
                                                                                                    }
                                                                                                , metadata = currentPage.route
                                                                                                , pageUrl = Nothing
                                                                                                }
                                                                                            )
                                                                                            |> Tuple.first

                                                                                    pageData2 : pageData
                                                                                    pageData2 =
                                                                                        config.errorPageToData error

                                                                                    viewValue : { title : String, body : List (Html (Pages.Msg.Msg userMsg)) }
                                                                                    viewValue =
                                                                                        (config.view Dict.empty Dict.empty Nothing currentPage Nothing sharedData pageData2 Nothing |> .view) pageModel
                                                                                in
                                                                                (ResponseSketch.HotUpdate pageData2 sharedData Nothing
                                                                                    |> config.encodeResponse
                                                                                    |> Bytes.Encode.encode
                                                                                )
                                                                                    |> (\encodedData ->
                                                                                            { route = currentPage.path |> Path.toRelative
                                                                                            , contentJson = Dict.empty
                                                                                            , html = viewValue.body |> bodyToString
                                                                                            , errors = []
                                                                                            , head = tags
                                                                                            , title = viewValue.title
                                                                                            , staticHttpCache = Dict.empty
                                                                                            , is404 = False
                                                                                            , statusCode =
                                                                                                case includeHtml of
                                                                                                    RenderRequest.OnlyJson ->
                                                                                                        200

                                                                                                    RenderRequest.HtmlAndJson ->
                                                                                                        config.errorStatusCode error
                                                                                            , headers = record.headers
                                                                                            }
                                                                                                |> ToJsPayload.PageProgress
                                                                                                |> Effect.SendSinglePageNew encodedData
                                                                                       )
                                                                in
                                                                renderedResult
                                                            )
                                                            (config.data (RenderRequest.maybeRequestPayload renderRequest |> Maybe.withDefault Json.Encode.null) serverRequestPayload.frontmatter)
                                                            config.sharedData
                                                            globalHeadTags
                                                    )

                                        Just notFoundReason ->
                                            render404Page config
                                                Nothing
                                                -- TODO do I need sharedDataResult?
                                                --(Result.toMaybe sharedDataResult)
                                                isDevServer
                                                serverRequestPayload.path
                                                notFoundReason
                                                |> DataSource.succeed
                                )

                    RenderRequest.Api ( path, ApiRoute apiHandler ) ->
                        DataSource.map2
                            (\response _ ->
                                case response of
                                    Just okResponse ->
                                        { body = okResponse
                                        , staticHttpCache = Dict.empty -- TODO do I need to serialize the full cache here, or can I handle that from the JS side?
                                        , statusCode = 200
                                        }
                                            |> ToJsPayload.SendApiResponse
                                            |> Effect.SendSinglePage

                                    Nothing ->
                                        render404Page config
                                            -- TODO do I need sharedDataResult here?
                                            Nothing
                                            isDevServer
                                            (Path.fromString path)
                                            NotFoundReason.NoMatchingRoute
                             --Err error ->
                             --    [ error ]
                             --        |> ToJsPayload.Errors
                             --        |> Effect.SendSinglePage
                            )
                            (apiHandler.matchesToResponse
                                (renderRequest
                                    |> RenderRequest.maybeRequestPayload
                                    |> Maybe.withDefault Json.Encode.null
                                )
                                path
                            )
                            globalHeadTags

                    RenderRequest.NotFound notFoundPath ->
                        (DataSource.map2
                            (\resolved1 resolvedGlobalHeadTags ->
                                render404Page config
                                    Nothing
                                    --(Result.toMaybe sharedDataResult)
                                    --model
                                    isDevServer
                                    notFoundPath
                                    NotFoundReason.NoMatchingRoute
                            )
                            (DataSource.succeed [])
                            globalHeadTags
                         -- TODO is there a way to resolve sharedData but get it as a Result if it fails?
                         --config.sharedData
                        )
                )

        initialModel : Model route
        initialModel =
            { staticResponses = staticResponsesNew
            , errors = []
            , allRawResponses = Dict.empty
            , maybeRequestJson = renderRequest
            , isDevServer = isDevServer
            }
    in
    StaticResponses.nextStep initialModel
        |> nextStepToEffect site
            config
            initialModel


updateAndSendPortIfDone :
    SiteConfig
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Model route
    -> ( Model route, Effect )
updateAndSendPortIfDone site config model =
    StaticResponses.nextStep
        model
        |> nextStepToEffect site config model


{-| -}
update :
    SiteConfig
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Msg
    -> Model route
    -> ( Model route, Effect )
update site config msg model =
    case msg of
        GotDataBatch batch ->
            let
                updatedModel : Model route
                updatedModel =
                    model
                        |> StaticResponses.batchUpdate batch
            in
            StaticResponses.nextStep
                updatedModel
                |> nextStepToEffect site config updatedModel

        GotBuildError buildError ->
            let
                updatedModel : Model route
                updatedModel =
                    { model
                        | errors =
                            buildError :: model.errors
                    }
            in
            StaticResponses.nextStep
                updatedModel
                |> nextStepToEffect site config updatedModel


nextStepToEffect :
    SiteConfig
    -> ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Model route
    -> ( StaticResponses Effect, StaticResponses.NextStep route Effect )
    -> ( Model route, Effect )
nextStepToEffect site config model ( updatedStaticResponsesModel, nextStep ) =
    case nextStep of
        StaticResponses.Continue httpRequests ->
            let
                updatedModel : Model route
                updatedModel =
                    { model
                        | staticResponses = updatedStaticResponsesModel
                    }
            in
            if List.isEmpty httpRequests then
                nextStepToEffect site
                    config
                    updatedModel
                    (StaticResponses.nextStep
                        updatedModel
                    )

            else
                ( updatedModel
                , (httpRequests
                    |> List.map Effect.FetchHttp
                  )
                    |> Effect.Batch
                )

        StaticResponses.FinishedWithErrors errors ->
            ( model
            , errors |> ToJsPayload.Errors |> Effect.SendSinglePage
            )

        StaticResponses.Finish finalValue ->
            ( model
            , finalValue
            )


render404Page :
    ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage
    -> Maybe sharedData
    -> Bool
    -> Path
    -> NotFoundReason
    -> Effect
render404Page config sharedData isDevServer path notFoundReason =
    case ( isDevServer, sharedData ) of
        ( False, Just justSharedData ) ->
            let
                byteEncodedPageData : Bytes
                byteEncodedPageData =
                    ResponseSketch.HotUpdate
                        (config.errorPageToData config.notFoundPage)
                        justSharedData
                        -- TODO remove shared action data
                        Nothing
                        |> config.encodeResponse
                        |> Bytes.Encode.encode

                pageModel : userModel
                pageModel =
                    config.init
                        Pages.Flags.PreRenderFlags
                        justSharedData
                        pageData
                        Nothing
                        Nothing
                        |> Tuple.first

                pageData : pageData
                pageData =
                    config.errorPageToData config.notFoundPage

                pathAndRoute : { path : Path, route : route }
                pathAndRoute =
                    { path = path, route = config.notFoundRoute }

                viewValue : { title : String, body : List (Html (Pages.Msg.Msg userMsg)) }
                viewValue =
                    (config.view Dict.empty
                        Dict.empty
                        Nothing
                        pathAndRoute
                        Nothing
                        justSharedData
                        pageData
                        Nothing
                        |> .view
                    )
                        pageModel
            in
            { route = Path.toAbsolute path
            , contentJson = Dict.empty
            , html = viewValue.body |> bodyToString
            , errors = []
            , head = config.view Dict.empty Dict.empty Nothing pathAndRoute Nothing justSharedData pageData Nothing |> .head
            , title = viewValue.title
            , staticHttpCache = Dict.empty
            , is404 = True
            , statusCode = 404
            , headers = []
            }
                |> ToJsPayload.PageProgress
                |> Effect.SendSinglePageNew byteEncodedPageData

        _ ->
            let
                byteEncodedPageData : Bytes
                byteEncodedPageData =
                    ResponseSketch.NotFound { reason = notFoundReason, path = path }
                        |> config.encodeResponse
                        |> Bytes.Encode.encode

                notFoundDocument : { title : String, body : List (Html msg) }
                notFoundDocument =
                    { path = path
                    , reason = notFoundReason
                    }
                        |> NotFoundReason.document config.pathPatterns
            in
            { route = Path.toAbsolute path
            , contentJson = Dict.empty
            , html = bodyToString notFoundDocument.body
            , errors = []
            , head = []
            , title = notFoundDocument.title
            , staticHttpCache = Dict.empty

            -- TODO can I handle caching from the JS-side only?
            --model.allRawResponses |> Dict.Extra.filterMap (\_ v -> v)
            , is404 = True
            , statusCode = 404
            , headers = []
            }
                |> ToJsPayload.PageProgress
                |> Effect.SendSinglePageNew byteEncodedPageData


bodyToString : List (Html msg) -> String
bodyToString body =
    body |> List.map (HtmlPrinter.htmlToString Nothing) |> String.join "\n"


urlToRoute : ProgramConfig userMsg userModel route pageData actionData sharedData effect mappedMsg errorPage -> Url -> route
urlToRoute config url =
    if url.path |> String.startsWith "/____elm-pages-internal____" then
        config.notFoundRoute

    else
        config.urlToRoute url
