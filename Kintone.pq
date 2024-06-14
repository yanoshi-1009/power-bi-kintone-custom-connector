// This file contains your Data Connector logic
[Version = "1.0.0"]
section Kintone;

[DataSource.Kind = "Kintone", Publish = "Kintone.Publish"]
shared Kintone.Contents = Value.ReplaceType(GetAllKintoneRecords, KintoneConnectorConfigType);

KintoneConnectorConfigType = type function (
    subDomain as (
        type text meta [
            Documentation.FieldCaption = "Subdomain",
            Documentation.FieldDescription = "The subdomain of your Kintone. For example, if your Kintone URL is https://example.cybozu.com, the subdomain is example."
        ]
    ),
    domain as (
        type text meta [
            Documentation.FieldCaption = "Domain",
            Documentation.FieldDescription = "The domain of your Kintone. For example, if your Kintone URL is https://example.cybozu.com, the domain is cybozu.com.",
            Documentation.AllowedValues = {"cybozu.com", "kintone.com", "cybozu.cn"}
        ]
    ),
    appId as (
        type number meta [
            Documentation.FieldCaption = "App ID",
            Documentation.FieldDescription = "The ID of the Kintone App you want to connect to.",
            Documentation.SampleValues = 1
        ]
    ),
    optional fieldCodes as (
        type text meta [
            Documentation.FieldCaption = "Field Codes",
            Documentation.FieldDescription = "The field codes of the fields you want to retrieve. If you leave this field empty, all fields will be retrieved.",
            Documentation.SampleValues = "company_name,employee_name"
        ]
    ),
    optional guestSpaceId as (
        type number meta [
            Documentation.FieldCaption = "Guest Space ID",
            Documentation.FieldDescription = "The guest space ID of the Kintone App you want to connect to. If you leave this field empty, the default space will be used.",
            Documentation.SampleValues = 1
        ]
    )
) as table meta [
    Documentation.Name = "Kintone Connector",
    Documentation.LongDescription = "This section is used to set the description for the Kintone data source."
];

GetAllKintoneRecords = (
    subDomain as text, domain as text, appId as number, optional fieldCodes as text, optional guestSpaceId as number
) as table =>
    let
        baseUrl = "https://" & subDomain & "." & domain,
        requestKintoneApi = (path as text, query as record) as record =>
            let
                userName = Extension.CurrentCredential()[Username],
                password = Extension.CurrentCredential()[Password],
                apiKey = Extension.CurrentCredential()[Key],
                headers =
                    if apiKey = null then
                        [
                            #"X-Cybozu-Authorization" = Binary.ToText(
                                Text.ToBinary(userName & ":" & password), BinaryEncoding.Base64
                            )
                        ]
                    else
                        [
                            #"X-Cybozu-API-Token" = apiKey
                        ],
                result = Web.Contents(baseUrl, [
                    Headers = headers,
                    RelativePath = path,
                    Query = query
                ])
            in
                Json.Document(result),
        getAppFields = () as record =>
            let
                relativePath =
                    if guestSpaceId = null then
                        "k/v1/app/form/fields.json"
                    else
                        "/k/guest/" & Text.From(guestSpaceId) & "/v1/app/form/fields.json",
                query = [
                    app = Text.From(appId)
                ]
            in
                requestKintoneApi(relativePath, query),
        getRecords = (query as text) as record =>
            let
                relativePath =
                    if guestSpaceId = null then
                        "/k/v1/records.json"
                    else
                        "/k/guest/" & Text.From(guestSpaceId) & "/v1/records.json",
                query = [
                    query = query,
                    // $id is always included in the response to get the next records
                    app = Text.From(appId),
                    fields = if fieldCodes = null then {} else List.Combine({{"$id"}, Text.Split(fieldCodes, ",")})
                ]
            in
                requestKintoneApi(relativePath, query),
        getAllRecords = (lastId as number, rawRecords as list) as list =>
            let
                LIMIT = 500,
                kintoneRestApiResp = getRecords(
                    "$id > " & Text.From(lastId) & " order by $id asc limit " & Text.From(LIMIT)
                ),
                kintoneRecords = kintoneRestApiResp[records],
                allRecords =
                    if List.Count(kintoneRecords) = LIMIT then
                        let
                            newLastId = Number.FromText(List.Last(kintoneRecords)[#"$id"][value])
                        in
                            List.Combine({rawRecords, @getAllRecords(newLastId, kintoneRecords)})
                    else
                        List.Combine({rawRecords, kintoneRecords})
            in
                allRecords,
        extractValuesFromEachFields = (kintoneRecord as record) as record =>
            let
                extractFieldValue = (fieldObject as record) as any =>
                    let
                        fieldType = fieldObject[type],
                        fieldValue =
                            if fieldType <> "SUBTABLE" then
                                fieldObject[value]
                            else
                                let
                                    subtableValue = fieldObject[value],
                                    extractedSubtableFieldValues = List.Transform(
                                        subtableValue, (subtableRow) => @extractValuesFromEachFields(subtableRow)
                                    )
                                in
                                    extractedSubtableFieldValues
                    in
                        fieldValue,
                kintoneRecordFieldCodes = Record.FieldNames(kintoneRecord),
                newRecord = Record.FromList(
                    List.Transform(
                        kintoneRecordFieldCodes,
                        (fieldCode) => extractFieldValue(Record.Field(kintoneRecord, fieldCode))
                    ),
                    kintoneRecordFieldCodes
                )
            in
                newRecord,
        createTypeList = (kintoneFields as record, kintoneRecord as record) as list =>
            let
                kintoneRecordFieldCodes = Record.FieldNames(kintoneRecord),
                determinType = (fieldCode as text, optional fieldFormat as text) as type =>
                    let
                        fieldType =
                            if fieldFormat = null then
                                Record.Field(kintoneRecord, fieldCode)[type]
                            else
                                fieldFormat,
                        textValueFields = {
                            "RECORD_NUMBER",
                            "SINGLE_LINE_TEXT",
                            "MULTI_LINE_TEXT",
                            "RICH_TEXT",
                            "LINK",
                            "RADIO_BUTTON",
                            "DROP_DOWN",
                            "STATUS",
                            "HOUR_MINUTE",
                            "DAY_HOUR_MINUTE"
                        },
                        numberValueFields = {"__ID__", "__REVISION__", "NUMBER", "NUMBER_DIGIT"},
                        calcField = {"CALC"},
                        dateValueFields = {"DATE"},
                        dateTimeValueFields = {"CREATED_TIME", "UPDATED_TIME", "DATETIME"},
                        timeValueFields = {"TIME"},
                        listValueFields = {"CHECK_BOX", "MULTI_SELECT", "CATEGORY"},
                        objectValueFields = {"CREATOR", "MODIFIER"},
                        objectListValueFields = {
                            "USER_SELECT",
                            "ORGANIZATION_SELECT",
                            "GROUP_SELECT",
                            "FILE",
                            "STATUS_ASSIGNEE",
                            "SUBTABLE"
                        },
                        columnType =
                            if List.Contains(textValueFields, fieldType) then
                                type text
                            else if List.Contains(numberValueFields, fieldType) then
                                type number
                                // The field type of CALC is determined by the format
                            else if List.Contains(calcField, fieldType) then
                                let
                                    fieldFormat = Record.Field(kintoneFields, fieldCode)[format],
                                    columnType = @determinType(fieldCode, fieldFormat)
                                in
                                    columnType
                            else if List.Contains(dateValueFields, fieldType) then
                                type date
                            else if List.Contains(dateTimeValueFields, fieldType) then
                                type datetime
                            else if List.Contains(timeValueFields, fieldType) then
                                type time
                            else if List.Contains(listValueFields, fieldType) then
                                type any
                            else if List.Contains(objectValueFields, fieldType) then
                                type any
                            else if List.Contains(objectListValueFields, fieldType) then
                                type any
                            else
                                Error.Record("UnsupportedFieldType", "Unsupported field type: " & fieldType)
                    in
                        columnType,
                kintoneFieldTypes = List.Transform(
                    kintoneRecordFieldCodes, (fieldCode as text) => {fieldCode, determinType(fieldCode)}
                )
            in
                kintoneFieldTypes,
        // Main
        fields = getAppFields()[properties],
        allRawRecords = getAllRecords(0, {}),
        convertedRecords = List.Transform(allRawRecords, (rawRecord) => extractValuesFromEachFields(rawRecord)),
        columnTypeList = createTypeList(fields, allRawRecords{0}),
        allRecordsTable = Table.FromRecords(convertedRecords),
        convertedTable = Table.TransformColumnTypes(allRecordsTable, columnTypeList)
    in
        convertedTable;

// Data Source Kind description
Kintone = [
    TestConnection = (dataSourcePath) =>
        let
            config = Json.Document(dataSourcePath),
            subDomain = config[subDomain],
            domain = config[domain],
            appId = config[appId]
        in
            {"Kintone.Contents", subDomain, domain, appId},
    Authentication = [
        Key = [
            KeyLabel = "API Token",
            Label = "API Token"
        ],
        UsernamePassword = [
            UsernameLabel = "Login Name",
            PasswordLabel = "Password",
            Label = "Username and Password"
        ]
    ],
    Label = Extension.LoadString("Kintone")
];

// Data Source UI publishing description
Kintone.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = {Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp")},
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = Kintone.Icons,
    SourceTypeImage = Kintone.Icons
];

Kintone.Icons = [
    Icon16 = {
        Extension.Contents("Kintone16.png"),
        Extension.Contents("Kintone20.png"),
        Extension.Contents("Kintone24.png"),
        Extension.Contents("Kintone32.png")
    },
    Icon32 = {
        Extension.Contents("Kintone32.png"),
        Extension.Contents("Kintone40.png"),
        Extension.Contents("Kintone48.png"),
        Extension.Contents("Kintone64.png")
    }
];
