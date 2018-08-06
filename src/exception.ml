open Core_kernel

open Util

module Mechanism = struct
  type t =
    { type_ : string
    ; description : string option
    ; help_link : string option
    ; handled : bool option
    (* TODO: meta *)
    ; data : string String.Map.t }

  let make ~type_ ?description ?help_link ?handled ?(data=String.Map.empty)
        () =
    { type_ ; description ; help_link ; handled ; data }

  let to_payload { type_ ; description ; help_link ; handled ; data } =
    { Payloads_t.type_ ; description ; help_link ; handled
    ; data = map_to_alist_option data }
end

module Frame = struct
  type t =
    { filename : string option
    ; function_ : string option
    ; module_ : string option
    ; lineno : int option
    ; colno : int option
    ; abs_path : string option
    ; context_line : string option
    ; pre_context : string list
    ; post_context : string list
    ; in_app : bool option
    ; vars : string String.Map.t
    ; package : string option
    ; platform : Platform.t option
    (* TODO: image_addr, instruction_addr, symbol_addr, instruction_offset *) }

  let make ?filename ?function_ ?module_ ?lineno ?colno ?abs_path
        ?context_line ?(pre_context=[]) ?(post_context=[]) ?in_app
        ?(vars=String.Map.empty) ?package ?platform () =
    [ filename ; function_ ; module_ ]
    |> List.for_all ~f:Option.is_none
    |> function
    | true ->
      Or_error.error_string "One of filename, function_ or module_ is \
                             required in Frame.make"
    | false ->
      Ok { filename
         ; function_
         ; module_
         ; lineno
         ; colno
         ; abs_path
         ; context_line
         ; pre_context
         ; post_context
         ; in_app
         ; vars
         ; package
         ; platform }

  let make_exn ?filename ?function_ ?module_ ?lineno ?colno ?abs_path
        ?context_line ?pre_context ?post_context ?in_app
        ?vars ?package ?platform () =
    make ?filename ?function_ ?module_ ?lineno ?colno ?abs_path
      ?context_line ?pre_context ?post_context ?in_app
      ?vars ?package ?platform ()
    |> Or_error.ok_exn

  let to_payload { filename ; function_ ; module_ ; lineno ; colno
                 ; abs_path ; context_line ; pre_context ; post_context
                 ; in_app ; vars ; package ; platform } =
    { Payloads_t.filename ; function_ ; module_ ; lineno ; colno ; abs_path
    ; context_line
    ; pre_context = empty_list_option pre_context
    ; post_context = empty_list_option post_context
    ; in_app
    ; vars = map_to_alist_option vars
    ; package ; platform }
end

type t =
  { type_ : string
  ; value : string option
  ; module_ : string option
  ; thread_id : string option
  ; mechanism : Mechanism.t option
  ; stacktrace : Frame.t list }

let make ~type_ ?value ?module_ ?thread_id ?mechanism ?(stacktrace=[]) () =
  { type_ ; value ; module_ ; thread_id ; mechanism ; stacktrace }

let to_payload { type_ ; value ; module_ ; thread_id ; mechanism
               ; stacktrace } =
  { Payloads_t.type_ ; value ; module_ ; thread_id
  ; mechanism = Option.map mechanism ~f:Mechanism.to_payload
  ; stacktrace =
      List.map stacktrace ~f:Frame.to_payload
      |> empty_list_option
      |> Option.map ~f:(fun frames ->
        { Payloads_t.frames }) }

let list_to_payload t =
  let values = List.map t ~f:to_payload in
  { Payloads_t.values }

let of_exn exn =
  let stacktrace =
    Caml.Printexc.get_raw_backtrace ()
    |> Caml.Printexc.backtrace_slots
    |> Option.value ~default:[||]
    |> Array.to_list
    (* Frames should be sorted from oldest to newest. *)
    |> List.rev
    |> List.filter_map ~f:(fun frame ->
      match Caml.Printexc.Slot.location frame with
      | None -> None
      | Some { Caml.Printexc.filename ; line_number ; start_char
             ; end_char } ->
        Frame.make ~filename ~lineno:line_number ~colno:start_char ()
        |> Option.some)
    |> Or_error.all
    (* Asserting that there are no errors here since we always pass
       ~filename to Frame.make *)
    |> Or_error.ok_exn
  in
  let type_ =
    (* exn_slot_name prints something like Module__filename.Submodule.Exn_name,
       but we only want Exn_name *)
    Caml.Printexc.exn_slot_name exn
    |> String.split ~on:'.'
    |> List.last_exn
  in
  let value =
    let str = Exn.to_string exn in
    (* Try to extract nicer info from the string output *)
    (* TODO: Handle non-sexp exceptions, which print like:
       Sentry__Exception.Custom_no_sexp_exception("This is a test", _)
    *)
    try
      Sexp.of_string str
      |> function
        (* Exceptions using [@@deriving sexp_of] will be in the form
           (Exception_name "message" other args) *)
      | Sexp.List (Atom name :: msgs)
        when String.is_suffix ~suffix:type_ name ->
        begin match msgs with
        | [] -> None
        | [ Atom msg ] -> Some msg
        | sexp -> Sexp.to_string_hum (Sexp.List sexp) |> Option.some
        end
      (* Handles argumentless exceptions like Not_found *)
      | Atom name when String.is_suffix ~suffix:type_ name -> None
      | _ -> assert false
    with _ -> Some str
  in
  make ~type_ ?value ~stacktrace ()

let of_error err =
  let open Error.Internal_repr in
  let rec find_backtrace = function
    | With_backtrace (_, bt) -> Some bt
    | Tag_t (_, t)
    | Tag_arg (_, _, t) -> find_backtrace t
    | Of_list (_, l) ->
      List.find_map l ~f:find_backtrace
    | _ -> None
  in
  match of_info err with
  | Exn exn -> of_exn exn
  | info ->
    let _backtrace = find_backtrace info in
    (* TODO: Parse backtrace *)
    let type_ = "Error" in
    let value = Error.to_string_hum err in
    make ~type_ ~value ()

let exn_test_helper e =
  begin try
    raise e
  with e ->
    of_exn e
    |> to_payload
    |> Payloads_j.string_of_exception_value
    |> print_endline
  end

let%expect_test "parse exn to payload" =
  exn_test_helper (Failure "This is a test");
  [%expect {| {"type":"Failure","value":"This is a test","stacktrace":{"frames":[{"filename":"src/exception.ml","lineno":182,"colno":4}]}} |}]

let%expect_test "parse Not_found to payload" =
  exn_test_helper Caml.Not_found;
  [%expect {| {"type":"Not_found","stacktrace":{"frames":[{"filename":"src/exception.ml","lineno":182,"colno":4}]}} |}]

exception Custom_sexp_exception of string * int list [@@deriving sexp_of]

let%expect_test "parse complex sexp exn to payload" =
  exn_test_helper (Custom_sexp_exception ("This is a test", [ 4 ; 2 ]));
  [%expect {| {"type":"Custom_sexp_exception","value":"(\"This is a test\" (4 2))","stacktrace":{"frames":[{"filename":"src/exception.ml","lineno":182,"colno":4}]}} |}]

exception Custom_no_sexp_exception of string * int list

let%expect_test "parse complex no-sexp exn to payload" =
  exn_test_helper (Custom_no_sexp_exception ("This is a test", [ 4 ; 2 ]));
  [%expect {| {"type":"Custom_no_sexp_exception","value":"(\"Sentry__Exception.Custom_no_sexp_exception(\\\"This is a test\\\", _)\")","stacktrace":{"frames":[{"filename":"src/exception.ml","lineno":182,"colno":4}]}} |}]

let%expect_test "parse Error.t to payload" =
  Error.of_string "This is different test"
  |> of_error
  |> to_payload
  |> Payloads_j.string_of_exception_value
  |> print_endline;
  [%expect {|  {"type":"Error","value":"This is different test"} |}]
