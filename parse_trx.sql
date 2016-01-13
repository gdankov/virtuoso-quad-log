-- See function read_log in https://github.com/openlink/virtuoso-opensource/blob/master/libsrc/Wi/recovery.c
-- (last accessed in commit a9e42032b70280d31e48b0fed99ffe9ebd1fd124)

-- virtuoso-opensource/libsrc/Wi/log.h contains the names for the flags that are contained in line[0]

-- The following cases are handled
-- #define LOG_INSERT         1  /* prime row as DV_STRING */
-- #define LOG_KEY_INSERT    13
-- #define LOG_INSERT_REPL    8
-- #define LOG_INSERT_SOFT    9  /* prime key row follows, like insert. */
-- #define LOG_DELETE         3  /* prime key as DV_STRING */
-- #define LOG_KEY_DELETE    14

-- the following cases are ignored
-- #define LOG_UPDATE         2  /* prime key as DV_STRING, cols as DV_ARRAY_OF_LONG, value as DV_ARRAY_OF_POINTER */
-- #define LOG_COMMIT         4
-- #define LOG_ROLLBACK       5
-- #define LOG_DD_CHANGE      6
-- #define LOG_CHECKPOINT     7
-- #define LOG_TEXT          10 /* SQL string follows */
-- #define LOG_SEQUENCE      11 /* series name, count */
-- #define LOG_SEQUENCE_64   12 /* series name, count */
-- #define LOG_USER_TEXT     15 /* SQL string log'd by an user */


create procedure parse_trx_files (in path varchar) {
  declare files, error, filename, i any;

  if (cfg_item_value(virtuoso_ini_path(), 'Parameters', 'CheckpointAuditTrail') = '0') {
    --I'm not sure how to throw an error. This works as well
    result_names (error);
    result ('CheckpointAuditTrail is not enabled. This will cause me to miss updates. Therefore I will not run!');
  } else {
    files := file_dirlist(path, 1);
    gvector_sort(files, 1, 0, 0); --for a plain array the 2nd and 3d elements should be 1 and 0. non-zero for the last argument indicates ascending sort
    -- skip the first one, it might still be changing
    for (i := 1; i < length(files); i := i + 1) {
      if (ends_with(files[i], '.trx')) {
        if (not ends_with(path, '/')) {
          filename := concat(path, '/', files[i]);
        } else {
          filename := concat(path, files[i]);
        }
        parse_trx(filename);
      }
    }
    result ('# start: isql-junk', ' ', ' ', ' ', ' ');
  }
}

create procedure parse_trx (in f varchar) {
  declare h, op, g, s, p, o, line, lines any;
  declare pos int;

  result_names (op, s, p, o, g);
  result (concat('# start: ', f), ' ', ' ', ' ', ' ');

  h := file_open (f, 0);
  while ((lines := read_log (h, pos)) is not null) {
    declare quad any;
    declare i int;
    quad := null;

    for (i := 0; i < length (lines); i := i + 1) {
      line := lines[i];
      if (line[0] in (1, 8, 9, 13)) { -- LOG_INSERT, LOG_INSERT_SOFT, LOG_INSERT_REPL and LOG_KEY_INSERT are all additions
        op := 'A';
        if (line[0] = 13) {
          quad := line[2]; -- with LOG_KEY_INSERT a flag is inserted in the line so the quad ends up in line[2] instead of line[1]
        }
        else {
          quad := line[1];
        }
      }
      else if (line[0] in (3, 14)) {-- LOG_DELETE and LOG_KEY_DELETE are both deletions
        op := 'D';
        quad := line[1];
      }

      if (quad is not null) { --if the operation was in one of the handled cases
        if (quad[0] = 271) {
          --There are a few tables and indexes that store the quads (select * from SYS_KEYS WHERE KEY_NAME like '%QUAD%')
          --The log contains a record for each index. It seems to me that the table DB.DBA.RDF_QUAD (id=271) is the one
          --that's always updated. So we can ignore the others
          result (op, parse_trx_format_iri(quad[2]), parse_trx_format_iri(quad[3]), parse_trx_format_object(quad[4]), parse_trx_format_iri(quad[1]));
        }
      }
    }
  }
}
;

--turn the IRI in an encoded iri or a blank node
--see also: 'IRI_ID Type' in http://docs.openlinksw.com/virtuoso/rdfdatarepresentation.html
create procedure parse_trx_format_iri (in iri any) {
  if (iri > min_64bit_bnode_iri_id()) {
    return concat('<_:', ltrim(concat(iri, ''), '#'), '>');
  } else {
    return concat('<', __ro2sq(iri), '>');
  }
}
;

--turn the object part into an encoded literal or an iri
--see also: 'Programatically resolving DB.DBA.RDF_QUAD.O to SQL' in http://docs.openlinksw.com/virtuoso/rdfdatarepresentation.html
create procedure parse_trx_format_object (in object any) {
  declare result, objectType, languageTag any;
  if (isiri_id(object)) {
    return parse_trx_format_iri(object);
  } else {
    result := concat('"', __ro2sq(object), '"');
    objectType := __ro2sq(DB.DBA.RDF_DATATYPE_OF_OBJ(object));
    languageTag := __ro2sq(DB.DBA.RDF_LANGUAGE_OF_OBJ(object));
    if (languageTag <> '') {
      result := concat(result, '@', languageTag);
    } else if (objectType <> '') {
      result := concat(result, '^^', objectType);
    }
    return result;
  }
}
;
