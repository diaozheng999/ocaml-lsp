open Import

let client_capabilities (state : State.t) =
  match state.init with
  | Uninitialized -> assert false
  | Initialized c -> c.capabilities

let make_error = Jsonrpc.Response.Error.make

let not_supported () =
  Jsonrpc.Response.Error.raise
    (make_error ~code:InternalError ~message:"Request not supported yet!" ())

let initialize_info : InitializeResult.t =
  let codeActionProvider =
    let codeActionKinds =
      [ CodeActionKind.Other Action_destruct.action_kind
      ; CodeActionKind.Other Action_inferred_intf.action_kind
      ; CodeActionKind.Other Action_type_annotate.action_kind
      ]
    in
    `CodeActionOptions (CodeActionOptions.create ~codeActionKinds ())
  in
  let textDocumentSync =
    `TextDocumentSyncOptions
      (TextDocumentSyncOptions.create ~openClose:true
         ~change:TextDocumentSyncKind.Incremental ~willSave:false
         ~save:(`Bool true) ~willSaveWaitUntil:false ())
  in
  let codeLensProvider = CodeLensOptions.create ~resolveProvider:false () in
  let completionProvider =
    (* TODO even if this re-enabled in general, it should stay disabled for
       emacs. It makes completion too slow *)
    CompletionOptions.create ~triggerCharacters:[ "."; "#" ]
      ~resolveProvider:true ()
  in
  let signatureHelpProvider =
    SignatureHelpOptions.create
      ~triggerCharacters:[ " "; "~"; "?"; ":"; "(" ]
      ()
  in
  let renameProvider =
    `RenameOptions (RenameOptions.create ~prepareProvider:true ())
  in
  let capabilities =
    let experimental =
      `Assoc
        [ ( "ocamllsp"
          , `Assoc
              [ ("interfaceSpecificLangId", `Bool true)
              ; Req_switch_impl_intf.capability
              ; Req_infer_intf.capability
              ] )
        ]
    in
    ServerCapabilities.create ~textDocumentSync ~hoverProvider:(`Bool true)
      ~declarationProvider:(`Bool true) ~definitionProvider:(`Bool true)
      ~typeDefinitionProvider:(`Bool true) ~completionProvider
      ~signatureHelpProvider ~codeActionProvider ~codeLensProvider
      ~referencesProvider:(`Bool true) ~documentHighlightProvider:(`Bool true)
      ~documentFormattingProvider:(`Bool true)
      ~selectionRangeProvider:(`Bool true) ~documentSymbolProvider:(`Bool true)
      ~foldingRangeProvider:(`Bool true) ~experimental ~renameProvider ()
  in
  let serverInfo =
    let version = Version.get () in
    InitializeResult.create_serverInfo ~name:"ocamllsp" ~version ()
  in
  InitializeResult.create ~capabilities ~serverInfo ()

let ocamlmerlin_reason = "ocamlmerlin-reason"

let task_if_running (state : State.t) ~f =
  let open Fiber.O in
  let* running = Fiber.Pool.running state.detached in
  match running with
  | false -> Fiber.return ()
  | true -> Fiber.Pool.task state.detached ~f

let set_diagnostics rpc doc =
  let state : State.t = Server.state rpc in
  let uri = Document.uri doc in
  let create_diagnostic ?relatedInformation ?severity range message =
    Diagnostic.create ?relatedInformation ?severity ~range ~message
      ~source:"ocamllsp" ()
  in
  let async send =
    let open Fiber.O in
    let+ () =
      task_if_running state ~f:(fun () ->
          let open Fiber.O in
          let timer = Document.timer doc in
          let+ res = Scheduler.schedule timer send in
          match res with
          | Error `Cancelled
          | Ok () ->
            ())
    in
    ()
  in
  match Document.syntax doc with
  | Menhir
  | Ocamllex ->
    Fiber.return ()
  | Reason when Option.is_none (Bin.which ocamlmerlin_reason) ->
    let no_reason_merlin =
      let message =
        sprintf "Could not detect %s. Please install reason" ocamlmerlin_reason
      in
      create_diagnostic Range.first_line message
    in
    Diagnostics.set state.diagnostics (`Merlin (uri, [ no_reason_merlin ]));
    async (fun () -> Diagnostics.send state.diagnostics)
  | Reason
  | Ocaml ->
    async (fun () ->
        let open Fiber.O in
        let* diagnostics =
          let command =
            Query_protocol.Errors
              { lexing = true; parsing = true; typing = true }
          in
          Document.with_pipeline_exn doc (fun pipeline ->
              let errors = Query_commands.dispatch pipeline command in
              List.map errors ~f:(fun (error : Loc.error) ->
                  let loc = Loc.loc_of_report error in
                  let range = Range.of_loc loc in
                  let severity =
                    match error.source with
                    | Warning -> DiagnosticSeverity.Warning
                    | _ -> DiagnosticSeverity.Error
                  in
                  let message ppf m =
                    String.trim (Format.asprintf "%a@." ppf m)
                  in
                  let relatedInformation =
                    match error.sub with
                    | [] -> None
                    | _ :: _ ->
                      Some
                        (List.map error.sub ~f:(fun (sub : Loc.msg) ->
                             let location =
                               let range = Range.of_loc sub.loc in
                               Location.create ~range ~uri
                             in
                             let message = message Loc.print_sub_msg sub in
                             DiagnosticRelatedInformation.create ~location
                               ~message))
                  in
                  let message = message Loc.print_main error in
                  create_diagnostic ?relatedInformation range message ~severity))
        in
        Diagnostics.set state.diagnostics (`Merlin (uri, diagnostics));
        Diagnostics.send state.diagnostics)

let on_initialize rpc (ip : InitializeParams.t) =
  let state : State.t = Server.state rpc in
  let state = { state with init = Initialized ip } in
  let state =
    match ip.trace with
    | None -> state
    | Some trace -> { state with trace }
  in
  (initialize_info, state)

let code_action (state : State.t) (params : CodeActionParams.t) =
  let open Fiber.O in
  let store = state.store in
  let uri = params.textDocument.uri in
  let* doc = Fiber.return (Document_store.get store uri) in
  let code_action (kind, f) =
    match params.context.only with
    | Some set when not (List.mem set kind ~equal:Poly.equal) ->
      Fiber.return None
    | Some _
    | None ->
      let+ action_opt = f () in
      Option.map action_opt ~f:(fun action_opt -> `CodeAction action_opt)
  in
  let open Fiber.O in
  let+ code_action_results =
    Fiber.parallel_map ~f:code_action
      [ ( CodeActionKind.Other Action_destruct.action_kind
        , fun () -> Action_destruct.code_action doc params )
      ; ( CodeActionKind.Other Action_inferred_intf.action_kind
        , fun () -> Action_inferred_intf.code_action doc state params )
      ; ( CodeActionKind.Other Action_type_annotate.action_kind
        , fun () -> Action_type_annotate.code_action doc params )
      ]
  in
  let code_action_results = List.filter_opt code_action_results in
  match code_action_results with
  | [] -> None
  | l -> Some l

module Formatter = struct
  let jsonrpc_error (e : Fmt.error) =
    let message = Fmt.message e in
    let code : Jsonrpc.Response.Error.Code.t =
      match e with
      | Unsupported_syntax _
      | Unknown_extension _
      | Missing_binary _ ->
        InvalidRequest
      | Unexpected_result _ -> InternalError
    in
    make_error ~code ~message ()

  let run rpc doc =
    let open Fiber.O in
    let state = Server.state rpc in
    let* res = Fmt.run state.State.ocamlformat doc in
    match res with
    | Result.Error e ->
      let message = Fmt.message e in
      let error = jsonrpc_error e in
      let msg = ShowMessageParams.create ~message ~type_:Error in
      let open Fiber.O in
      let+ () =
        let state : State.t = Server.state rpc in
        task_if_running state ~f:(fun () ->
            Server.notification rpc (ShowMessage msg))
      in
      Jsonrpc.Response.Error.raise error
    | Result.Ok result -> Fiber.return (Some result)
end

let markdown_support (client_capabilities : ClientCapabilities.t) ~field =
  match client_capabilities.textDocument with
  | None -> false
  | Some td -> (
    match field td with
    | None -> false
    | Some format ->
      let set = Option.value format ~default:[ MarkupKind.Markdown ] in
      List.mem set MarkupKind.Markdown ~equal:Poly.equal)

let location_of_merlin_loc uri : _ -> (_, string) result = function
  | `At_origin -> Ok None
  | `Builtin _ -> Ok None
  | `File_not_found s -> Error (sprintf "File_not_found: %s" s)
  | `Invalid_context -> Ok None
  | `Not_found (ident, where) ->
    let msg = sprintf "%s not found." ident in
    let msg =
      match where with
      | None -> msg
      | Some w -> sprintf "%s last looked in %s" msg w
    in
    Error msg
  | `Not_in_env m -> Error (sprintf "not in environment: %s" m)
  | `Found (path, lex_position) ->
    Ok
      (Position.of_lexical_position lex_position
      |> Option.map ~f:(fun position ->
             let range = { Range.start = position; end_ = position } in
             let uri =
               match path with
               | None -> uri
               | Some path -> Uri.of_path path
             in
             let locs = [ { Location.uri; range } ] in
             `Location locs))

let format_doc ~markdown ~doc =
  `MarkupContent
    (if markdown then
      let value =
        match Doc_to_md.translate doc with
        | Raw d -> sprintf "(** %s *)" d
        | Markdown d -> d
      in
      { MarkupContent.value; kind = MarkupKind.Markdown }
    else
      { MarkupContent.value = doc; kind = MarkupKind.PlainText })

let format_contents ~syntax ~markdown ~typ ~doc =
  (* TODO for vscode, we should just use the language id. But that will not work
     for all editors *)
  let markdown_name = Document.Syntax.markdown_name syntax in
  `MarkupContent
    (if markdown then
      let value =
        match doc with
        | None -> sprintf "```%s\n%s\n```" markdown_name typ
        | Some s ->
          let doc =
            match Doc_to_md.translate s with
            | Raw d -> sprintf "(** %s *)" d
            | Markdown d -> d
          in
          sprintf "```%s\n%s\n```\n---\n%s" markdown_name typ doc
      in
      { MarkupContent.value; kind = MarkupKind.Markdown }
    else
      let value =
        match doc with
        | None -> sprintf "%s" typ
        | Some d -> sprintf "%s\n%s" typ d
      in
      { MarkupContent.value; kind = MarkupKind.PlainText })

let query_doc doc pos =
  let command = Query_protocol.Document (None, pos) in
  let open Fiber.O in
  let+ res = Document.dispatch_exn doc command in
  match res with
  | `Found s
  | `Builtin s ->
    Some s
  | _ -> None

let query_type doc pos =
  let command = Query_protocol.Type_enclosing (None, pos, None) in
  let open Fiber.O in
  let+ res = Document.dispatch_exn doc command in
  match res with
  | []
  | (_, `Index _, _) :: _ ->
    None
  | (location, `String value, _) :: _ -> Some (location, value)

let hover (state : State.t) { HoverParams.textDocument = { uri }; position; _ }
    =
  let store = state.store in
  let doc = Document_store.get store uri in
  let pos = Position.logical position in
  let client_capabilities = client_capabilities state in
  let open Fiber.O in
  (* TODO we shouldn't acquiring the merlin thread twice per request *)
  let* query_type = query_type doc pos in
  match query_type with
  | None -> Fiber.return None
  | Some (loc, typ) ->
    let syntax = Document.syntax doc in
    let+ doc = query_doc doc pos in
    let contents =
      let markdown =
        markdown_support client_capabilities ~field:(fun td ->
            Option.map td.hover ~f:(fun h -> h.contentFormat))
      in
      format_contents ~syntax ~markdown ~typ ~doc
    in
    let range = Range.of_loc loc in
    let resp = Hover.create ~contents ~range () in
    Some resp

let signature_help (state : State.t)
    { SignatureHelpParams.textDocument = { uri }; position; _ } =
  let store = state.store in
  let doc = Document_store.get store uri in
  let pos = Position.logical position in
  let client_capabilities = client_capabilities state in
  let prefix =
    (* The value of [short_path] doesn't make a difference to the final result
       because labels cannot include dots. However, a true value is slightly
       faster for getting the prefix. *)
    Compl.prefix_of_position (Document.source doc) pos ~short_path:true
  in
  let open Fiber.O in
  (* TODO use merlin resources efficiently and do everything in 1 thread *)
  let* application_signature =
    Document.with_pipeline_exn doc (fun pipeline ->
        let typer = Mpipeline.typer_result pipeline in
        let pos = Mpipeline.get_lexing_pos pipeline pos in
        let node = Mtyper.node_at typer pos in
        Merlin_analysis.Signature_help.application_signature node ~prefix)
  in
  match application_signature with
  | None ->
    let help = SignatureHelp.create ~signatures:[] () in
    Fiber.return help
  | Some a ->
    let fun_name = Option.value ~default:"_" a.function_name in
    let prefix = sprintf "%s : " fun_name in
    let offset = String.length prefix in
    let parameters =
      List.map a.parameters
        ~f:(fun (p : Merlin_analysis.Signature_help.parameter_info) ->
          let label = `Offset (offset + p.param_start, offset + p.param_end) in
          ParameterInformation.create ~label ())
    in
    let+ doc = query_doc doc a.function_position in
    let documentation =
      let open Option.O in
      let+ doc = doc in
      let markdown =
        markdown_support client_capabilities ~field:(fun td ->
            let* sh = td.signatureHelp in
            let+ si = sh.signatureInformation in
            si.documentationFormat)
      in
      format_doc ~markdown ~doc
    in
    let label = prefix ^ a.signature in
    let info =
      SignatureInformation.create ~label ?documentation ~parameters ()
    in
    SignatureHelp.create ~signatures:[ info ] ~activeSignature:0
      ?activeParameter:a.active_param ()

let text_document_lens (state : State.t)
    { CodeLensParams.textDocument = { uri }; _ } =
  let store = state.store in
  let doc = Document_store.get store uri in
  match Document.kind doc with
  | Intf -> Fiber.return []
  | Impl ->
    let open Fiber.O in
    let command = Query_protocol.Outline in
    let+ outline = Document.dispatch_exn doc command in
    let rec symbol_info_of_outline_item item =
      let children =
        List.concat_map item.Query_protocol.children
          ~f:symbol_info_of_outline_item
      in
      match item.Query_protocol.outline_type with
      | None -> children
      | Some typ ->
        let loc = item.Query_protocol.location in
        let info =
          let range = Range.of_loc loc in
          let command = Command.create ~title:typ ~command:"" () in
          CodeLens.create ~range ~command ()
        in
        info :: children
    in
    List.concat_map ~f:symbol_info_of_outline_item outline

let folding_range (state : State.t)
    { FoldingRangeParams.textDocument = { uri }; _ } =
  let doc = Document_store.get state.store uri in
  let command = Query_protocol.Outline in
  let open Fiber.O in
  let+ outline = Document.dispatch_exn doc command in
  let folds : FoldingRange.t list =
    let folding_range (range : Range.t) =
      FoldingRange.create ~startLine:range.start.line ~endLine:range.end_.line
        ~startCharacter:range.start.character ~endCharacter:range.end_.character
        ~kind:Region ()
    in
    let rec loop acc (items : Query_protocol.item list) =
      match items with
      | [] -> acc
      | item :: items ->
        let range = Range.of_loc item.location in
        if range.end_.line - range.start.line < 2 then
          loop acc items
        else
          let items = item.children @ items in
          let range = folding_range range in
          loop (range :: acc) items
    in
    loop [] outline
    |> List.sort ~compare:(fun x y -> Ordering.of_int (compare x y))
  in
  Some folds

let rename (state : State.t)
    { RenameParams.textDocument = { uri }; position; newName; _ } =
  let doc = Document_store.get state.store uri in
  let command =
    Query_protocol.Occurrences (`Ident_at (Position.logical position))
  in
  let open Fiber.O in
  let+ locs = Document.dispatch_exn doc command in
  let version = Document.version doc in
  let edits =
    List.map locs ~f:(fun loc ->
        let range = Range.of_loc loc in
        { TextEdit.newText = newName; range })
  in
  let workspace_edits =
    let client_capabilities = client_capabilities state in
    let documentChanges =
      let open Option.O in
      Option.value ~default:false
        (let* workspace = client_capabilities.workspace in
         let* edit = workspace.workspaceEdit in
         edit.documentChanges)
    in
    if documentChanges then
      let textDocument =
        OptionalVersionedTextDocumentIdentifier.create ~uri ~version ()
      in
      let edits = List.map edits ~f:(fun e -> `TextEdit e) in
      WorkspaceEdit.create
        ~documentChanges:
          [ `TextDocumentEdit (TextDocumentEdit.create ~textDocument ~edits) ]
        ()
    else
      WorkspaceEdit.create ~changes:[ (uri, edits) ] ()
  in
  workspace_edits

let selection_range (state : State.t)
    { SelectionRangeParams.textDocument = { uri }; positions; _ } =
  let selection_range_of_shapes (cursor_position : Position.t)
      (shapes : Query_protocol.shape list) : SelectionRange.t option =
    let rec ranges_of_shape parent s =
      let range = Range.of_loc s.Query_protocol.shape_loc in
      let selectionRange = { SelectionRange.range; parent } in
      match s.Query_protocol.shape_sub with
      | [] -> [ selectionRange ]
      | xs -> List.concat_map xs ~f:(ranges_of_shape (Some selectionRange))
    in
    let ranges = List.concat_map ~f:(ranges_of_shape None) shapes in
    (* try to find the nearest range inside first, then outside *)
    let nearest_range =
      List.min ranges ~f:(fun r1 r2 ->
          let inc (r : SelectionRange.t) =
            Position.compare_inclusion cursor_position r.range
          in
          match (inc r1, inc r2) with
          | `Outside x, `Outside y -> Position.compare x y
          | `Outside _, `Inside -> Gt
          | `Inside, `Outside _ -> Lt
          | `Inside, `Inside -> Range.compare_size r1.range r2.range)
    in
    nearest_range
  in
  let doc = Document_store.get state.store uri in
  let open Fiber.O in
  let+ ranges =
    Fiber.sequential_map positions ~f:(fun x ->
        let command = Query_protocol.Shape (Position.logical x) in
        let open Fiber.O in
        let+ shapes = Document.dispatch_exn doc command in
        selection_range_of_shapes x shapes)
  in
  List.filter_opt ranges

let references (state : State.t)
    { ReferenceParams.textDocument = { uri }; position; _ } =
  let doc = Document_store.get state.store uri in
  let command =
    Query_protocol.Occurrences (`Ident_at (Position.logical position))
  in
  let open Fiber.O in
  let+ locs = Document.dispatch_exn doc command in
  Some
    (List.map locs ~f:(fun loc ->
         let range = Range.of_loc loc in
         (* using original uri because merlin is looking only in local file *)
         { Location.uri; range }))

let definition_query server (state : State.t) uri position merlin_request =
  let doc = Document_store.get state.store uri in
  let position = Position.logical position in
  let command = merlin_request position in
  let open Fiber.O in
  let* result = Document.dispatch_exn doc command in
  match location_of_merlin_loc uri result with
  | Ok s -> Fiber.return s
  | Error message ->
    let+ () =
      task_if_running state ~f:(fun () ->
          let message = sprintf "Locate failed. %s" message in
          let log = LogMessageParams.create ~type_:Error ~message in
          Server.notification server (Server_notification.LogMessage log))
    in
    None

let highlight (state : State.t)
    { DocumentHighlightParams.textDocument = { uri }; position; _ } =
  let store = state.store in
  let doc = Document_store.get store uri in
  let command =
    Query_protocol.Occurrences (`Ident_at (Position.logical position))
  in
  let open Fiber.O in
  let+ locs = Document.dispatch_exn doc command in
  let lsp_locs =
    List.map locs ~f:(fun loc ->
        let range = Range.of_loc loc in
        (* using the default kind as we are lacking info to make a difference
           between assignment and usage. *)
        DocumentHighlight.create ~range ~kind:DocumentHighlightKind.Text ())
  in
  Some lsp_locs

let document_symbol (state : State.t) uri =
  let store = state.store in
  let doc = Document_store.get store uri in
  let client_capabilities = client_capabilities state in
  let open Fiber.O in
  let+ symbols = Document_symbol.run client_capabilities doc uri in
  Some symbols

(** handles requests for OCaml (syntax) documents *)
let ocaml_on_request :
    type resp.
       State.t Server.t
    -> resp Client_request.t
    -> (resp Reply.t * State.t) Fiber.t =
 fun rpc req ->
  let state = Server.state rpc in
  let store = state.store in
  let now res = Fiber.return (Reply.now res, state) in
  let later f req =
    Fiber.return
      ( Reply.later (fun k ->
            let open Fiber.O in
            let* resp = f state req in
            k resp)
      , state )
  in
  match req with
  | Client_request.Initialize ip ->
    let res, state = on_initialize rpc ip in
    Fiber.return (Reply.now res, state)
  | Client_request.Shutdown -> now ()
  | Client_request.DebugTextDocumentGet { textDocument = { uri }; position = _ }
    -> (
    match Document_store.get_opt store uri with
    | None -> now None
    | Some doc -> now (Some (Msource.text (Document.source doc))))
  | Client_request.DebugEcho params -> now params
  | Client_request.TextDocumentColor _ -> now []
  | Client_request.TextDocumentColorPresentation _ -> now []
  | Client_request.TextDocumentHover req -> later hover req
  | Client_request.TextDocumentReferences req -> later references req
  | Client_request.TextDocumentCodeLensResolve codeLens -> now codeLens
  | Client_request.TextDocumentCodeLens req -> later text_document_lens req
  | Client_request.TextDocumentHighlight req -> later highlight req
  | Client_request.WorkspaceSymbol _ -> now None
  | Client_request.DocumentSymbol { textDocument = { uri }; _ } ->
    later document_symbol uri
  | Client_request.TextDocumentDeclaration { textDocument = { uri }; position }
    ->
    later
      (fun state () ->
        definition_query rpc state uri position (fun pos ->
            Query_protocol.Locate (None, `MLI, pos)))
      ()
  | Client_request.TextDocumentDefinition
      { textDocument = { uri }; position; _ } ->
    later
      (fun state () ->
        definition_query rpc state uri position (fun pos ->
            Query_protocol.Locate (None, `ML, pos)))
      ()
  | Client_request.TextDocumentTypeDefinition
      { textDocument = { uri }; position; _ } ->
    later
      (fun state () ->
        definition_query rpc state uri position (fun pos ->
            Query_protocol.Locate_type pos))
      ()
  | Client_request.TextDocumentCompletion
      { textDocument = { uri }; position; _ } ->
    later
      (fun _ () ->
        let doc = Document_store.get store uri in
        let open Fiber.O in
        let+ resp = Compl.complete doc position in
        Some resp)
      ()
  | Client_request.TextDocumentPrepareRename
      { textDocument = { uri }; position } ->
    later
      (fun _ () ->
        let doc = Document_store.get store uri in
        let command =
          Query_protocol.Occurrences (`Ident_at (Position.logical position))
        in
        let open Fiber.O in
        let+ locs = Document.dispatch_exn doc command in
        let loc =
          List.find_opt locs ~f:(fun loc ->
              let range = Range.of_loc loc in
              Position.compare_inclusion position range = `Inside)
        in
        Option.map loc ~f:Range.of_loc)
      ()
  | Client_request.TextDocumentRename req -> later rename req
  | Client_request.TextDocumentFoldingRange req -> later folding_range req
  | Client_request.SignatureHelp req -> later signature_help req
  | Client_request.ExecuteCommand _ -> not_supported ()
  | Client_request.TextDocumentLinkResolve l -> now l
  | Client_request.TextDocumentLink _ -> now None
  | Client_request.WillSaveWaitUntilTextDocument _ -> now None
  | Client_request.CodeAction params -> later code_action params
  | Client_request.CodeActionResolve ca -> now ca
  | Client_request.CompletionItemResolve ci ->
    later
      (fun state () ->
        let markdown =
          markdown_support (client_capabilities state) ~field:(fun d ->
              let open Option.O in
              let+ completion = d.completion in
              let* completion_item = completion.completionItem in
              completion_item.documentationFormat)
        in
        let resolve = Compl.Resolve.of_completion_item ci in
        let doc =
          let uri = Compl.Resolve.uri resolve in
          Document_store.get state.store uri
        in
        Compl.resolve doc ci resolve query_doc ~markdown)
      ()
  | Client_request.TextDocumentFormatting
      { textDocument = { uri }; options = _; _ } ->
    later
      (fun _ () ->
        let doc = Document_store.get store uri in
        Formatter.run rpc doc)
      ()
  | Client_request.TextDocumentOnTypeFormatting _ -> now None
  | Client_request.SelectionRange req -> later selection_range req
  | Client_request.TextDocumentMoniker _ -> not_supported ()
  | Client_request.SemanticTokensFull _ -> not_supported ()
  | Client_request.SemanticTokensDelta _ -> not_supported ()
  | Client_request.SemanticTokensRange _ -> not_supported ()
  | Client_request.LinkedEditingRange _ -> not_supported ()
  | Client_request.UnknownRequest _ ->
    Jsonrpc.Response.Error.raise
      (make_error ~code:InvalidRequest ~message:"Got unknown request" ())

let on_request :
    type resp.
       State.t Server.t
    -> resp Client_request.t
    -> (resp Reply.t * State.t) Fiber.t =
 fun server req ->
  let state : State.t = Server.state server in
  let store = state.store in
  let syntax : Document.Syntax.t option =
    let open Option.O in
    let* td =
      Client_request.text_document req (fun ~meth:_ ~params:_ -> None)
    in
    let uri = td.uri in
    let+ doc = Document_store.get_opt store uri in
    Document.syntax doc
  in
  match req with
  | Client_request.UnknownRequest { meth; params } -> (
    match
      [ (Req_switch_impl_intf.meth, Req_switch_impl_intf.on_request)
      ; (Req_infer_intf.meth, Req_infer_intf.on_request)
      ]
      |> List.assoc_opt meth
    with
    | None ->
      Jsonrpc.Response.Error.raise
        (make_error ~code:InternalError ~message:"Unknown method"
           ~data:(`Assoc [ ("method", `String meth) ])
           ())
    | Some handler ->
      Fiber.return
        ( Reply.later (fun send ->
              let open Fiber.O in
              let* res = handler ~params state in
              send res)
        , state ))
  | _ -> (
    match syntax with
    | Some (Ocamllex | Menhir) -> not_supported ()
    | _ -> ocaml_on_request server req)

let on_notification server (notification : Client_notification.t) :
    State.t Fiber.t =
  let state : State.t = Server.state server in
  let store = state.store in
  match notification with
  | TextDocumentDidOpen params ->
    let open Fiber.O in
    let* doc =
      let delay = Configuration.diagnostics_delay state.configuration in
      let* timer = Scheduler.create_timer ~delay in
      Document.make timer state.merlin params
    in
    Document_store.put store doc;
    let+ () = set_diagnostics server doc in
    state
  | TextDocumentDidClose { textDocument = { uri } } ->
    let open Fiber.O in
    let+ () =
      Diagnostics.remove state.diagnostics (`Merlin uri);
      let* () = Document_store.remove_document store uri in
      task_if_running state ~f:(fun () -> Diagnostics.send state.diagnostics)
    in
    state
  | TextDocumentDidChange { textDocument = { uri; version }; contentChanges } ->
    let prev_doc = Document_store.get store uri in
    let open Fiber.O in
    let* doc = Document.update_text ~version prev_doc contentChanges in
    Document_store.put store doc;
    let+ () = set_diagnostics server doc in
    state
  | CancelRequest _ ->
    Log.log ~section:"debug" (fun () -> Log.msg "ignoring cancellation" []);
    Fiber.return state
  | ChangeConfiguration req ->
    (* TODO this is wrong and we should just fetch the config from the client
       after receiving this notification *)
    let configuration = Configuration.update state.configuration req in
    Fiber.return { state with configuration }
  | DidSaveTextDocument { textDocument = { uri }; _ } -> (
    let open Fiber.O in
    let state = Server.state server in
    match Document_store.get_opt state.store uri with
    | None ->
      ( Log.log ~section:"on receive DidSaveTextDocument" @@ fun () ->
        Log.msg "saved document is not in the store" [] );
      Fiber.return state
    | Some doc ->
      (* we need [update_text] with no changes to get a new merlin pipeline;
         otherwise the diagnostics don't get updated *)
      let* doc = Document.update_text doc [] in
      Document_store.put store doc;
      let+ () = set_diagnostics server doc in
      state)
  | WillSaveTextDocument _
  | ChangeWorkspaceFolders _
  | Initialized
  | WorkDoneProgressCancel _
  | Exit ->
    Fiber.return state
  | SetTrace { value } -> Fiber.return { state with trace = value }
  | Unknown_notification req ->
    let open Fiber.O in
    let+ () =
      task_if_running state ~f:(fun () ->
          let log =
            LogMessageParams.create ~type_:Error
              ~message:("Unknown notication " ^ req.method_)
          in
          Server.notification server (Server_notification.LogMessage log))
    in
    state

let start () =
  let store = Document_store.make () in
  let handler =
    let on_request = { Server.Handler.on_request } in
    Server.Handler.make ~on_request ~on_notification ()
  in
  let open Fiber.O in
  let* stream =
    let io = Lsp.Io.make stdin stdout in
    Lsp_fiber.Fiber_io.make io
  in
  let configuration = Configuration.default in
  let detached = Fiber.Pool.create () in
  let server = Fdecl.create Dyn.Encoder.opaque in
  let diagnostics =
    let workspace_root =
      lazy
        (let server = Fdecl.get server in
         let state = Server.state server in
         State.workspace_root state)
    in
    Diagnostics.create ~workspace_root (function
      | [] -> Fiber.return ()
      | diagnostics ->
        let server = Fdecl.get server in
        let state = Server.state server in
        task_if_running state ~f:(fun () ->
            let batch = Server.Batch.create server in
            List.iter diagnostics ~f:(fun d ->
                Server.Batch.notification batch (PublishDiagnostics d));
            Server.Batch.submit batch))
  in
  let dune = Dune.create diagnostics in
  let* server =
    let+ merlin = Scheduler.create_thread () in
    let ocamlformat = Fmt.create () in
    Fdecl.set server
      (Server.make handler stream
         { store
         ; init = Uninitialized
         ; merlin
         ; ocamlformat
         ; configuration
         ; detached
         ; dune
         ; trace = `Off
         ; diagnostics
         });
    Fdecl.get server
  in
  Fiber.fork_and_join_unit
    (fun () -> Fiber.Pool.run detached)
    (fun () ->
      let* () =
        Fiber.fork_and_join_unit
          (fun () -> Server.start server)
          (fun () ->
            let* state = Dune.run dune in
            let message =
              match state with
              | Error Binary_not_found ->
                Some "Dune must be installed for project functionality"
              | Error Out_of_date ->
                Some
                  "Dune is out of date. Install dune >= 3.0 for project \
                   functionality"
              | Ok () -> None
            in
            match message with
            | None -> Fiber.return ()
            (* We disable the warnings because dune 3.0 isn't available yet *)
            | Some _ when true -> Fiber.return ()
            | Some message ->
              let* (_ : InitializeParams.t) = Server.initialized server in
              let state = Server.state server in
              task_if_running state ~f:(fun () ->
                  let log = LogMessageParams.create ~type_:Warning ~message in
                  Server.notification server
                    (Server_notification.LogMessage log)))
      in
      Fiber.parallel_iter
        ~f:(fun f -> f ())
        [ (fun () -> Document_store.close store)
        ; (fun () -> Fiber.Pool.stop detached)
        ; (fun () -> Dune.stop dune)
        ])

let run () =
  Unix.putenv "__MERLIN_MASTER_PID" (string_of_int (Unix.getpid ()));
  Scheduler.run (start ())
