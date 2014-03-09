open Registry
open Asn_grammars
open Asn
open Utils

type certificate_failure =
  | InvalidCertificate
  | InvalidSignature
  | CertificateExpired
  | InvalidExtensions
  | InvalidPathlen
  | SelfSigned
  | NoTrustAnchor
  | InvalidInput
  | InvalidServerExtensions
  | InvalidServerName
  | InvalidCA

type verification_result = [
  | `Fail of certificate_failure
  | `Ok
]


(* TODO RFC 5280: A certificate MUST NOT include more than
                  one instance of a particular extension. *)

let issuer_matches_subject parent cert =
  Name.equal parent.tbs_cert.subject cert.tbs_cert.issuer

let is_self_signed cert = issuer_matches_subject cert cert

(* XXX should return the tbs_cert blob from the parser, this is insane *)
let raw_cert_hack cert raw =
  let siglen = Cstruct.len cert.signature_val in
  let off    = if siglen > 128 then 1 else 0 in
  Cstruct.(sub raw 4 (len raw - (siglen + 4 + 19 + off)))

let validate_signature trusted cert raw =
  let tbs_raw = raw_cert_hack cert raw in
  match trusted.tbs_cert.pk_info with

  | PK.RSA issuing_key ->

      let signature =
        Crypto.verifyRSA_and_unpadPKCS1 issuing_key cert.signature_val in

      ( match pkcs1_digest_info_of_cstruct signature with
        | None                   -> false
        | Some ((algo, hash), _) ->
           let compare_hashes hashfn = Utils.cs_eq hash (hashfn tbs_raw) in
           let open Algorithm in
           match (cert.signature_algo, algo) with
           | (MD5_RSA , MD5 ) -> compare_hashes Crypto.md5
           | (SHA1_RSA, SHA1) -> compare_hashes Crypto.sha
           | _ -> false )

  | _ -> false


let validate_time now cert =
(*   let from, till = cert.validity in *)
(* TODO:  from < now && now < till *)
  true

let validate_path_len pathlen cert =
  let open Extension in
  match extn_basic_constr cert with
  | None                                  -> true
  | Some (_ , Basic_constraints None)     -> true
  | Some (_ , Basic_constraints (Some n)) -> n >= pathlen

let validate_ca_extensions cert =
  let open Extension in
  (* comments from RFC5280 *)
  (* 4.2.1.9 Basic Constraints *)
  (* Conforming CAs MUST include this extension in all CA certificates used *)
  (* to validate digital signatures on certificates and MUST mark the *)
  (* extension as critical in such certificates *)
  (* unfortunately, there are 8 CA certs (including the one which
      signed google.com) which are _NOT_ marked as critical *)
  ( option false (const true) (extn_basic_constr cert) ) &&

  (* 4.2.1.3 Key Usage *)
  (* Conforming CAs MUST include key usage extension *)
  (* CA Cert (cacert.org) does not *)
  ( match extn_key_usage cert with
    (* When present, conforming CAs SHOULD mark this extension as critical *)
    (* yeah, you wish... *)
    | Some (crit, Key_usage usage) -> List.mem Key_cert_sign usage
    | _                            -> false ) &&

  (* Name Constraints - name constraints should match servername *)

  (* check criticality *)
  List.for_all (function
      | (true, Key_usage _)         -> true
      | (true, Basic_constraints _) -> true
      | (crit, _)                   -> not crit )
    cert.tbs_cert.extensions


let ext_authority_matches_subject trusted cert =
  let open Extension in
  match
    extn_authority_key_id cert, extn_subject_key_id trusted
  with
  | Some (_, Authority_key_id (Some auth, _, _)),
    Some (_, Subject_key_id au)                -> Utils.cs_eq auth au
  (* TODO: check exact rules in RFC5280 *)
  | Some (_, Authority_key_id (None, _, _)), _ -> true (* not mandatory *)
  | None, _                                    -> true (* not mandatory *)
  | _, _                                       -> false

let subject cert = map_find cert.tbs_cert.subject
                      ~f:(function Name.CN n -> Some n | _ -> None)

let common_name_to_string cert =
  match subject cert with
  | None   ->
     let sigl = Cstruct.len cert.signature_val in
     let sign = Cstruct.copy cert.signature_val 0 sigl in
     let hex = Cryptokit.(transform_string (Hexa.encode ()) sign) in
     "NO commonName " ^ hex
  | Some x -> x

let validate_relation pathlen trusted cert raw_cert =
  Printf.printf "verifying relation of %s -> %s (pathlen %d)\n"
                (common_name_to_string trusted)
                (common_name_to_string cert)
                pathlen;
  match
    issuer_matches_subject trusted cert,
    ext_authority_matches_subject trusted cert,
    validate_signature trusted cert raw_cert,
    validate_path_len pathlen trusted
  with
  | (true, true, true, true) ->
     Printf.printf "ok\n";
     `Ok
  | (false, _, _, _)         ->
     Printf.printf "issuer doesn't match subject\n";
     `Fail InvalidCertificate
  | (_, false, _, _)         ->
     Printf.printf "authority didn't match subject key id (in extensions)\n";
     `Fail InvalidExtensions
  | (_, _, false, _)         ->
     Printf.printf "signature is wrong!\n";
     `Fail InvalidSignature
  | (_, _, _, false)         ->
     Printf.printf "path len exceeded!\n";
     `Fail InvalidPathlen

let validate_server_extensions cert =
  let open Extension in
  List.for_all (function
      | (_, Basic_constraints (Some _)) -> false
      | (_, Basic_constraints None    ) -> true
      (* key_encipherment (RSA) *)
      (* signing (DHE_RSA) *)
      | (_, Key_usage usage    ) -> List.mem Key_encipherment usage
      | (_, Ext_key_usage usage) -> List.mem Server_auth usage
      | (c, Policies ps        ) -> not c || List.mem `Any ps
      (* we've to deal with _all_ extensions marked critical! *)
      | (crit, _)                -> not crit )
    cert.tbs_cert.extensions

let verify_certificate now cert =
    Printf.printf "verify intermediate certificate %s\n"
                  (common_name_to_string cert);
    match
      validate_time now cert,
      validate_ca_extensions cert
    with
    | (true, true) -> Printf.printf "success\n";
                      `Ok
    | (false, _)   -> Printf.printf "validity failed\n";
                      `Fail CertificateExpired
    | (_, false)   -> Printf.printf "extensions failed\n";
                      `Fail InvalidExtensions

let verify_ca_cert now cert raw =
  Printf.printf "verifying CA cert %s: " (common_name_to_string cert);
  match
    is_self_signed cert,
    validate_signature cert cert raw,
    validate_time now cert,
    validate_ca_extensions cert
  with
  | (true, true, true, true) ->
     Printf.printf "ok\n";
     `Ok
  | (false, _, _, _)         ->
     Printf.printf "not self-signed CA\n";
     `Fail InvalidCA
  | (_, false, _, _)         ->
     Printf.printf "signature failed\n";
     `Fail InvalidSignature
  | (_, _, false, _)         ->
     Printf.printf "validity failed\n";
     `Fail CertificateExpired
  | (_, _, _, false)         ->
     Printf.printf "extensions failed\n";
     `Fail InvalidExtensions

(* XXX OHHH, i soooo want to be parameterized by (pre-parsed) trusted certs...  *)
let find_trusted_certs now =
  let cacert_file, ca_nss_file =
    ("../certificates/cacert.crt", "../certificates/ca-root-nss.crt") in
  let ((cacert, raw), nss) =
    Crypto_utils.(cert_of_file cacert_file, certs_of_file ca_nss_file) in

  let cas   = List.append nss [(cacert, raw)] in
  let valid = List.filter (fun (cert, raw) ->
                             match verify_ca_cert now cert raw with
                             | `Ok     -> true
                             | `Fail _ -> false)
                          cas
  in
  Printf.printf "read %d certificates, could validate %d\n" (List.length cas) (List.length valid);
  let certs, _ = List.split valid in
  certs

let hostname_matches cert name =
  let open Extension in
  match extn_subject_alt_name cert with
  | Some (_, Subject_alt_name names) ->
      List.exists
        (function General_name.DNS x -> x = name | _ -> false)
        names
  | _ -> option false ((=) name) (subject cert)

let verify_server_certificate ?servername now cert =
  Printf.printf "verify server certificate %s\n"
                (common_name_to_string cert);
  match
    validate_time now cert,
    option false (hostname_matches cert) servername,
    validate_server_extensions cert
  with
  | (true, true, true) ->
      Printf.printf "successfully verified server certificate\n";
      `Ok
  | (false, _, _)      ->
      Printf.printf "failed to verify validity of server certificate\n";
      `Fail CertificateExpired
  | (_, false, _)      ->
      Printf.printf "failed to verify servername of server certificate\n";
      `Fail InvalidServerName
  | (_, _, false)      ->
      Printf.printf "failed to verify extensions of server certificate\n";
      `Fail InvalidServerExtensions

let find_issuer trusted cert =
  (* first have to find issuer of ``c`` in ``trusted`` *)
  Printf.printf "looking for issuer of %s (%d CAs)\n"
                (common_name_to_string cert)
                (List.length trusted);
  match List.filter (fun p -> issuer_matches_subject p cert) trusted with
  | []  -> Printf.printf "couldn't find trusted CA cert\n"; None
  | [t] -> (match ext_authority_matches_subject t cert with
            | true -> Some t
            | false -> Printf.printf "authority key didn't match issuing CA";
                       None)
  | _   -> Printf.printf "found multiple CAs where subject matched, giving up\n";
           None

(* this is the API for a user (Cstruct.t might go away) *)
(* XXX
 * Both Sys.time() and trusted anchors should be moved towards the user!
 * A general kernel-less tls validator doesn't go out and read rondom cert
 * files. It doesn't even look at the clock.
 *)

let (>>) a f = match a with
  | `Ok -> f ()
  | err -> err

let verify_certificates ?servername : (certificate * Cstruct.t) list -> verification_result
= function
    (* we get the certificate chain cs:
        [c0; c1; c2; ... ; cn], n > 0
        let server = c0
        let top = cn
       strategy:
        1. traverse left-to-right, checking c_n+1 signs c_n
        2. include servername and different extension constraints for c0
        3. at the end, try to establish a trust anchor
      path: all c_n certs are path-n from server. while veryfing each one, make
            sure c_n+1 has basic constraints >= n
    *)
  | []                                    -> `Fail InvalidInput
  | (server, server_raw) :: certs_and_raw ->

      let now     = Sys.time () in
      let trusted = find_trusted_certs now in

      let rec verify_certs = function
        | []                 -> `Ok
        | (cert, _) :: certs ->
            verify_certificate now cert >> fun () -> verify_certs certs
      in

      let rec climb pathlen cert cert_raw = function
        | (super, super_raw) :: certs ->
            validate_relation pathlen super cert cert_raw >> fun () ->
            climb (succ pathlen) super super_raw certs
        | [] ->
            match find_issuer trusted cert with
            | None when is_self_signed cert             -> `Fail SelfSigned
            | None                                      -> `Fail NoTrustAnchor
            | Some anchor when validate_time now anchor ->
                validate_relation pathlen anchor cert cert_raw
            | Some _                                    -> `Fail CertificateExpired
      in

      verify_server_certificate ?servername now server >> fun () ->
      verify_certs certs_and_raw                       >> fun () ->
      climb 0 server server_raw certs_and_raw


(* TODO: how to deal with
    2.16.840.1.113730.1.1 - Netscape certificate type
    2.16.840.1.113730.1.12 - SSL server name
    2.16.840.1.113730.1.13 - Netscape certificate comment *)

(* stuff from 4366 (TLS extensions):
  - root CAs
  - client cert url *)

(* Future TODO Certificate Revocation Lists and OCSP (RFC6520)
2.16.840.1.113730.1.2 - Base URL
2.16.840.1.113730.1.3 - Revocation URL
2.16.840.1.113730.1.4 - CA Revocation URL
2.16.840.1.113730.1.7 - Renewal URL
2.16.840.1.113730.1.8 - Netscape CA policy URL

2.5.4.38 - id-at-authorityRevocationList
2.5.4.39 - id-at-certificateRevocationList

2.5.29.20 - CRL Number
2.5.29.21 - reason code
2.5.29.27 - Delta CRL indicator
2.5.29.28 - Issuing Distribution Point
2.5.29.31 - CRL Distribution Points
2.5.29.46 - FreshestCRL

do not forget about 'authority information access' (private internet extension -- 4.2.2 of 5280) *)

(* Future TODO: Policies
2.5.29.32 - Certificate Policies
2.5.29.33 - Policy Mappings
2.5.29.36 - Policy Constraints
 *)

(* Future TODO: anything with subject_id and issuer_id ? seems to be not used by anybody *)

(* - test setup (ACM CCS'12):
            self-signed cert with requested commonName,
            self-signed cert with other commonName,
            valid signed cert with other commonName
   - also of interest: international domain names, wildcards *)

(* alternative approach: interface and implementation for certificate pinning *)
(* alternative approach': notary system / perspectives *)
(* alternative approach'': static list of trusted certificates *)
