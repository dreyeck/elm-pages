module Form exposing (..)

import DataSource exposing (DataSource)
import Date exposing (Date)
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attr
import Server.Request as Request exposing (Request)


type Form value view
    = Form
        (List
            ( List (FieldInfoSimple view)
            , List view -> List view
            )
        )
        (Request value)
        (Request
            (DataSource
                (List
                    ( String
                    , { errors : List String
                      , raw : String
                      }
                    )
                )
            )
        )


type Field value view
    = Field (FieldInfo value view)


type alias FieldInfoSimple view =
    { name : String
    , initialValue : Maybe String
    , type_ : String
    , min : Maybe String
    , max : Maybe String
    , serverValidation : String -> DataSource (List String)
    , toHtml :
        FinalFieldInfo
        -> Maybe { raw : String, errors : List String }
        -> view
    }


type alias FieldInfo value view =
    { name : String
    , initialValue : Maybe String
    , type_ : String
    , min : Maybe String
    , max : Maybe String
    , serverValidation : String -> DataSource (List String)
    , toHtml :
        FinalFieldInfo
        -> Maybe { raw : String, errors : List String }
        -> view
    , decode : String -> value
    }


type alias FinalFieldInfo =
    { name : String
    , initialValue : Maybe String
    , type_ : String
    , min : Maybe String
    , max : Maybe String
    , serverValidation : String -> DataSource (List String)
    }


succeed : constructor -> Form constructor view
succeed constructor =
    Form []
        (Request.succeed constructor)
        (Request.succeed (DataSource.succeed []))


toInputRecord :
    String
    -> Maybe { raw : String, errors : List String }
    -> FinalFieldInfo
    ->
        { toInput : List (Html.Attribute Never)
        , toLabel : List (Html.Attribute Never)
        , errors : List String
        }
toInputRecord name info field =
    { toInput =
        [ Attr.name name |> Just
        , case info of
            Just { raw } ->
                Just (Attr.value raw)

            _ ->
                field.initialValue |> Maybe.map Attr.value
        , field.type_ |> Attr.type_ |> Just
        , field.min |> Maybe.map Attr.min
        , field.max |> Maybe.map Attr.max
        , Attr.required True |> Just
        ]
            |> List.filterMap identity
    , toLabel =
        [ Attr.for name ]
    , errors = info |> Maybe.map .errors |> Maybe.withDefault []
    }


input :
    String
    ->
        ({ toInput : List (Html.Attribute Never)
         , toLabel : List (Html.Attribute Never)
         , errors : List String
         }
         -> view
        )
    -> Field String view
input name toHtmlFn =
    Field
        { name = name
        , initialValue = Nothing
        , type_ = "text"
        , min = Nothing
        , max = Nothing
        , serverValidation = \_ -> DataSource.succeed []
        , toHtml =
            \fieldInfo info ->
                toHtmlFn (toInputRecord name info fieldInfo)
        , decode = identity
        }


submit :
    ({ attrs : List (Html.Attribute Never)
     }
     -> view
    )
    -> Field () view
submit toHtmlFn =
    Field
        { name = ""
        , initialValue = Nothing
        , type_ = "submit"
        , min = Nothing
        , max = Nothing
        , serverValidation = \_ -> DataSource.succeed []
        , toHtml =
            \fieldInfo info ->
                toHtmlFn
                    { attrs =
                        [ Attr.type_ "submit" ]
                    }
        , decode = \_ -> ()
        }


view :
    view
    -> Field () view
view viewFn =
    Field
        { name = ""
        , initialValue = Nothing
        , type_ = "submit"
        , min = Nothing
        , max = Nothing
        , serverValidation = \_ -> DataSource.succeed []
        , toHtml =
            \fieldInfo info ->
                viewFn
        , decode = \_ -> ()
        }



--number : { name : String, label : String } -> Field
--number { name, label } =
--    Field
--        { name = name
--        , label = label
--        , initialValue = Nothing
--        , type_ = "number"
--        , min = Nothing
--        , max = Nothing
--        , serverValidation = \_ -> DataSource.succeed []
--        }


date :
    String
    ->
        ({ toInput : List (Html.Attribute Never)
         , toLabel : List (Html.Attribute Never)
         , errors : List String
         }
         -> view
        )
    -- TODO should be Date type
    -> Field Date view
date name toHtmlFn =
    Field
        { name = name
        , initialValue = Nothing
        , type_ = "date"
        , min = Nothing
        , max = Nothing
        , serverValidation = \_ -> DataSource.succeed []
        , toHtml =
            \fieldInfo info ->
                toHtmlFn (toInputRecord name info fieldInfo)
        , decode =
            \rawString ->
                Date.fromIsoString rawString
                    |> Result.withDefault (Date.fromRataDie 0)
        }


withMin : Int -> Field value view -> Field value view
withMin min (Field field) =
    Field { field | min = min |> String.fromInt |> Just }


withMax : Int -> Field value view -> Field value view
withMax max (Field field) =
    Field { field | max = max |> String.fromInt |> Just }


withMinDate : String -> Field value view -> Field value view
withMinDate min (Field field) =
    Field { field | min = min |> Just }


withMaxDate : String -> Field value view -> Field value view
withMaxDate max (Field field) =
    Field { field | max = max |> Just }


type_ : String -> Field value view -> Field value view
type_ typeName (Field field) =
    Field
        { field | type_ = typeName }


withInitialValue : String -> Field value view -> Field value view
withInitialValue initialValue (Field field) =
    Field { field | initialValue = Just initialValue }


withServerValidation : (value -> DataSource (List String)) -> Field value view -> Field value view
withServerValidation serverValidation (Field field) =
    Field
        { field
            | serverValidation = field.decode >> serverValidation
        }


required : Field value view -> Form (value -> form) view -> Form form view
required (Field field) (Form fields decoder serverValidations) =
    let
        thing : Request (DataSource (List ( String, { raw : String, errors : List String } )))
        thing =
            Request.map2
                (\arg1 arg2 ->
                    arg1
                        |> DataSource.map2 (::)
                            (field.serverValidation arg2
                                |> DataSource.map
                                    (\validationErrors ->
                                        ( field.name
                                        , { errors = validationErrors
                                          , raw = arg2
                                          }
                                        )
                                    )
                            )
                )
                serverValidations
                (Request.formField_ field.name)
    in
    Form
        (addField field fields)
        (decoder
            |> Request.andMap (Request.formField_ field.name |> Request.map field.decode)
        )
        thing


addField : FieldInfo value view -> List ( List (FieldInfoSimple view), List view -> List view ) -> List ( List (FieldInfoSimple view), List view -> List view )
addField field list =
    case list of
        [] ->
            [ ( [ simplify2 field ], identity )
            ]

        ( fields, wrapFn ) :: others ->
            ( simplify2 field :: fields, wrapFn ) :: others


append : Field value view -> Form form view -> Form form view
append (Field field) (Form fields decoder serverValidations) =
    Form
        --(field :: fields)
        (addField field fields)
        decoder
        serverValidations


appendForm : (form1 -> form2 -> form) -> Form form1 view -> Form form2 view -> Form form view
appendForm mapFn (Form fields1 decoder1 serverValidations1) (Form fields2 decoder2 serverValidations2) =
    Form
        -- TODO is this ordering correct?
        (fields1 ++ fields2)
        (Request.map2 mapFn decoder1 decoder2)
        (Request.map2
            (DataSource.map2 (++))
            serverValidations1
            serverValidations2
        )


wrap : (List view -> view) -> Form form view -> Form form view
wrap newWrapFn (Form fields decoder serverValidations) =
    Form (wrapFields fields newWrapFn) decoder serverValidations


wrapFields :
    List
        ( List (FieldInfoSimple view)
        , List view -> List view
        )
    -> (List view -> view)
    ->
        List
            ( List (FieldInfoSimple view)
            , List view -> List view
            )
wrapFields fields newWrapFn =
    case fields of
        [] ->
            [ ( [], newWrapFn >> List.singleton )
            ]

        ( existingFields, wrapFn ) :: others ->
            ( existingFields
            , wrapFn >> newWrapFn >> List.singleton
            )
                :: others


simplify : FieldInfo value view -> FinalFieldInfo
simplify field =
    { name = field.name
    , initialValue = field.initialValue
    , type_ = field.type_
    , min = field.min
    , max = field.max
    , serverValidation = field.serverValidation
    }


simplify2 : FieldInfo value view -> FieldInfoSimple view
simplify2 field =
    { name = field.name
    , initialValue = field.initialValue
    , type_ = field.type_
    , min = field.min
    , max = field.max
    , serverValidation = field.serverValidation
    , toHtml = field.toHtml
    }


simplify3 : FieldInfoSimple view -> FinalFieldInfo
simplify3 field =
    { name = field.name
    , initialValue = field.initialValue
    , type_ = field.type_
    , min = field.min
    , max = field.max
    , serverValidation = field.serverValidation
    }



{-
   - If there is at least one file field, then use enctype multi-part. Otherwise use form encoding (or maybe GET with query params?).
   - Should it ever use GET forms?
   - Ability to do server-only validations (like uniqueness check with DataSource)
   - Return error messages that can be presented inline from server response (both on full page load and on client-side request)
   - Add functions for built-in form validations
-}


toHtml : (List (Html.Attribute msg) -> List view -> view) -> Maybe (Dict String { raw : String, errors : List String }) -> Form value view -> view
toHtml toForm serverValidationErrors (Form fields decoder serverValidations) =
    toForm
        [ Attr.method "POST"
        ]
        (fields
            |> List.reverse
            |> List.concatMap
                (\( nestedFields, wrapFn ) ->
                    nestedFields
                        |> List.reverse
                        |> List.map
                            (\field ->
                                field.toHtml
                                    (simplify3 field)
                                    (serverValidationErrors
                                        |> Maybe.andThen (Dict.get field.name)
                                    )
                            )
                        |> wrapFn
                )
        )


toRequest : Form value view -> Request value
toRequest (Form fields decoder serverValidations) =
    Request.expectFormPost
        (\_ ->
            decoder
        )


toRequest2 :
    Form value view
    ->
        Request
            (DataSource
                (Result
                    (Dict
                        String
                        { errors : List String
                        , raw : String
                        }
                    )
                    ( value
                    , Dict
                        String
                        { errors : List String
                        , raw : String
                        }
                    )
                )
            )
toRequest2 (Form fields decoder serverValidations) =
    Request.map2
        (\decoded errors ->
            errors
                |> DataSource.map
                    (\validationErrors ->
                        if hasErrors validationErrors then
                            validationErrors
                                |> Dict.fromList
                                |> Err

                        else
                            Ok
                                ( decoded
                                , validationErrors
                                    |> Dict.fromList
                                )
                    )
        )
        (Request.expectFormPost
            (\_ ->
                decoder
            )
        )
        (Request.expectFormPost
            (\_ ->
                serverValidations
            )
        )


hasErrors : List ( String, { errors : List String, raw : String } ) -> Bool
hasErrors validationErrors =
    List.any
        (\( _, entry ) ->
            entry.errors |> List.isEmpty |> not
        )
        validationErrors
