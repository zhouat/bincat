%{
   
    let missing_item item section =
      (* error message printing *)
      Log.error (Printf.sprintf "missing %s in section %s\n" item section);;
       
    (* current library name *)
    let libname = ref "";;
		      
    (* temporary table to store tainting rules on functions of a given library *)
    let libraries = Hashtbl.create 7;;

    (* name of binary file to analyze *)
    let filename = ref ""
 
    (* temporay table used to check that all mandatory elements are filled in the configuration file *)
    let mandatory_keys = Hashtbl.create 20;;
      
    let mandatory_items = [
	(MEM_MODEL, "mem-model", "settings");
	(MODE, "mode", "settings");
	(CALL_CONV, "call-conv", "settings");
	(MEM_SZ, "mem-sz", "settings");
	(OP_SZ, "op-sz", "settings");
	(STACK_WIDTH, "stack-width", "settings");
	(SS, "ss", "loader");
	(DS, "ds", "loader");
	(CS, "cs", "loader");
	(ES, "es", "loader");
	(FS, "fs", "loader");
	(GS, "gs", "loader");
	(ENTRYPOINT, "entrypoint", "loader");
	(CODE_LENGTH, "code-length", "loader");
	(FORMAT, "format", "binary");
	(FILEPATH, "filepath", "binary");
	(PHYS_CODE_ADDR, "phys-code-addr", "loader");
	(DOTFILE, "dotfile", "analyzer");
	(GDT, "gdt", "gdt");
	(RVA_CODE, "rva-code", "loader");
      ];;	
      List.iter (fun (k, kname, sname) -> Hashtbl.add mandatory_keys k (kname, sname, false)) mandatory_items;;

      (** fills the table of initial values for the given register *)
      let init_register r (c, t) =
	let r' = Register.of_name r in
	begin
	  match c with
	  None    -> ()
	| Some c' -> Hashtbl.add Config.initial_register_content r' c'
	end;
	match t with
	  None    -> ()
	| Some t' -> Hashtbl.add Config.initial_register_tainting r' t'


      (** fills the table of initial values for the given memory address *)
      let core_init_mem a ((c: Config.cvalue option), t) content_tbl tainting_tbl =
	begin
	  match c with
	  None    -> ()
	| Some c' -> Hashtbl.add content_tbl a c'
	end;
	match t with
	  None    -> ()
	| Some t' -> Hashtbl.add tainting_tbl a t'

      let init_memory a c = core_init_mem a c Config.initial_memory_content Config.initial_memory_tainting
      let init_stack a c = core_init_mem a c Config.initial_stack_content Config.initial_stack_tainting
      let init_heap a c = core_init_mem	a c Config.initial_heap_content Config.initial_heap_tainting
					
      let update_mandatory key =
	let kname, sname, _ = Hashtbl.find mandatory_keys key in
	Hashtbl.replace mandatory_keys key (kname, sname, true);;
	
      (** footer function *)
      let check_context () =
	(* check whether all mandatory items are provided *)
	Hashtbl.iter (fun _ (pname, sname, b) -> if not b then missing_item pname sname) mandatory_keys;
	(* open the binary to pick up the text section *)
	let fid  =
	  try
	    let fid = open_in_bin !filename in
	    seek_in fid !Config.phys_code_addr;
	    fid
	  with _ -> Log.error "failed to open the binary to analyze"
			   
	in
	Config.text := String.make !Config.code_length '\x00';
	let len = input fid !Config.text 0 !Config.code_length in
	if len <> !Config.code_length then Log.error "extraction of the byte sequence containing code has failed";
	(* fill the table of tainting rules for each provided library *)
	let add_tainting_rules l (c, funs) =
	  let c' =
	    match c with
	      None    -> !Config.call_conv
	    | Some c' -> c'
	  in
	  let add (fname, c, r, args) =
	    let c' =
	      match c with
		None 	-> c'
	      | Some c' -> c'
	    in
	    Config.add_tainting_rules l (fname, (c', r, args))
	  in
	  List.iter add (List.rev funs)
	in
	Hashtbl.iter add_tainting_rules libraries
	;;
	
	%}
%token EOF LEFT_SQ_BRACKET RIGHT_SQ_BRACKET EQUAL REG MEM STAR AT TAINT
%token CALL_CONV CDECL FASTCALL STDCALL MEM_MODEL MEM_SZ OP_SZ STACK_WIDTH
%token ANALYZER UNROLL DS CS SS ES FS GS FLAT SEGMENTED BINARY STATE CODE_LENGTH
%token FORMAT PE ELF ENTRYPOINT FILEPATH MASK MODE REAL PROTECTED PHYS_CODE_ADDR
%token LANGLE_BRACKET RANGLE_BRACKET LPAREN RPAREN COMMA SETTINGS UNDERSCORE LOADER DOTFILE
%token GDT RVA_CODE CUT ASSERT IMPORTS CALL U T STACK RANGE HEAP
%token <string> STRING
%token <Z.t> INT
%start <unit> process
%%
(* in every below rule a later rule in the file order may inhibit a previous rule *) 
  process:
      | s=sections EOF { s; check_context () }
	
      
    sections:
    | s=section 	       { s }
    | ss=sections s=section    { ss; s }
    
      section:
    | LEFT_SQ_BRACKET SETTINGS RIGHT_SQ_BRACKET s=settings   { s }
    | LEFT_SQ_BRACKET LOADER RIGHT_SQ_BRACKET 	l=loader     { l }
    | LEFT_SQ_BRACKET BINARY RIGHT_SQ_BRACKET 	b=binary     { b }
    | LEFT_SQ_BRACKET STATE RIGHT_SQ_BRACKET  st=state       { st }
    | LEFT_SQ_BRACKET ANALYZER RIGHT_SQ_BRACKET a=analyzer   { a }
    | LEFT_SQ_BRACKET GDT RIGHT_SQ_BRACKET gdt=gdt 	     { gdt }
    | LEFT_SQ_BRACKET l=libname RIGHT_SQ_BRACKET lib=library { l; lib }
    | LEFT_SQ_BRACKET ASSERT RIGHT_SQ_BRACKET r=assert_rules { r }
    | LEFT_SQ_BRACKET IMPORTS RIGHT_SQ_BRACKET i=imports     { i }

      imports:							     
    |                     { () }
    | i=import l=imports  { i ; l }

      import:
    | a=INT EQUAL libname=STRING COMMA fname=STRING { Hashtbl.replace Config.imports a (libname, fname) }
			       
      libname:
    | l=STRING { libname := l; Hashtbl.add libraries l (None, []) }
     	       
      settings:
    | s=setting_item 		 { s }
    | s=setting_item ss=settings { s; ss }
    
      setting_item:
    | MEM_MODEL EQUAL m=memmodel { update_mandatory MEM_MODEL; Config.memory_model := m }
    | CALL_CONV EQUAL c=callconv { update_mandatory CALL_CONV; Config.call_conv := c }
    | OP_SZ EQUAL i=INT          { update_mandatory OP_SZ; try Config.operand_sz := Z.to_int i with _ -> Log.error "illegal operand size" }
    | MEM_SZ EQUAL i=INT         { update_mandatory MEM_SZ; try Config.address_sz := Z.to_int i with _ -> Log.error "illegal address size" }
    | STACK_WIDTH EQUAL i=INT    { update_mandatory STACK_WIDTH; try Config.stack_width := Z.to_int i with _ -> Log.error "illegal stack width" }
    | MODE EQUAL m=mmode         { update_mandatory MODE ; Config.mode := m }
				 	
      memmodel:
    | FLAT 	{ Config.Flat }
    | SEGMENTED { Config.Segmented }

      callconv:
    | CDECL    { Config.Cdecl } 
    | FASTCALL { Config.Fastcall }
    | STDCALL  { Config.Stdcall }
    

      mmode:
    | PROTECTED { Config.Protected }
    | REAL 	{ Config.Real }

	
      loader:
    | l=loader_item 	      { l }
    | l=loader_item ll=loader { l; ll }

      loader_item:
    | CS EQUAL i=init         	 { update_mandatory CS; init_register "cs" i }
    | DS EQUAL i=init          	 { update_mandatory DS; init_register "ds" i }
    | SS EQUAL i=init          	 { update_mandatory SS; init_register "ss" i }
    | ES EQUAL i=init 	      	 { update_mandatory ES; init_register "es" i }
    | FS EQUAL i=init 	      	 { update_mandatory FS; init_register "fs" i }
    | GS EQUAL i=init 	      	 { update_mandatory GS; init_register "gs" i }
    | CODE_LENGTH EQUAL i=INT 	 { update_mandatory CODE_LENGTH; Config.code_length := Z.to_int i }
    | ENTRYPOINT EQUAL i=INT  	 { update_mandatory ENTRYPOINT; Config.ep := i }
    | PHYS_CODE_ADDR EQUAL i=INT { update_mandatory PHYS_CODE_ADDR; Config.phys_code_addr := Z.to_int i }
    | RVA_CODE EQUAL i=INT 	 { update_mandatory RVA_CODE; Config.rva_code := i }
    
      
      binary:
    | b=binary_item 	      { b }
    | b=binary_item bb=binary { b; bb }
	
      binary_item:
    | FILEPATH EQUAL f=STRING 	{ update_mandatory FILEPATH; filename := f }
    | FORMAT EQUAL f=format 	{ update_mandatory FORMAT; Config.format := f }


		
      format:
    | PE  { Config.Pe }
    | ELF { Config.Elf }
    
      gdt:
    | g=gdt_item 	{ g }
    | g=gdt_item gg=gdt { g; gg }

      gdt_item:
    | GDT LEFT_SQ_BRACKET i=INT RIGHT_SQ_BRACKET EQUAL v=INT { update_mandatory GDT; Hashtbl.replace Config.gdt i v }
		       
      
      analyzer:
    | a=analyzer_item 		  { a }
    | a=analyzer_item aa=analyzer { a; aa }
				    
      analyzer_item:
    | UNROLL EQUAL i=INT { Config.unroll := Z.to_int i }
    | DOTFILE EQUAL f=STRING { update_mandatory DOTFILE; Config.dotfile := f }
    | CUT EQUAL l=addresses { List.iter (fun a -> Config.blackAddresses := Config.SAddresses.add a !Config.blackAddresses) l }

     addresses:
    | i=INT { [ i ] }
    | i=INT COMMA l=addresses { i::l }
			      
      state:
    | s=state_item 	    { s }
    | s=state_item ss=state { s; ss }

      state_item:
    | REG LEFT_SQ_BRACKET r=STRING RIGHT_SQ_BRACKET EQUAL v=init    { init_register r v }
    | MEM LEFT_SQ_BRACKET m=repeat RIGHT_SQ_BRACKET EQUAL v=init    { init_memory m v }
    | STACK LEFT_SQ_BRACKET m=repeat RIGHT_SQ_BRACKET EQUAL v=init  { init_stack m v }
    | HEAP LEFT_SQ_BRACKET m=repeat RIGHT_SQ_BRACKET EQUAL v=init   { init_heap m v }

      repeat:
    | i=INT { (i, Z.one) }
    | i=INT STAR n=INT { (i, n) }
		       
      library:
    | l=library_item 		{ l }
    | l=library_item ll=library { l; ll }

      library_item:
    | CALL_CONV EQUAL c=callconv  { let funs = snd (Hashtbl.find libraries !libname) in Hashtbl.replace libraries !libname (Some c, funs)  }
    | v=fun_rule 		  { let f, c, a = v in let cl, funs = Hashtbl.find libraries !libname in Hashtbl.replace libraries !libname (cl, (f, c, None, a)::funs) }
    | r=argument EQUAL v=fun_rule { let f, c, a = v in let cl, funs = Hashtbl.find libraries !libname in Hashtbl.replace libraries !libname (cl, (f, c, Some r, a)::funs) }
  			     
      fun_rule:
    | f=STRING LANGLE_BRACKET c=callconv RANGLE_BRACKET a=arguments { f, Some c, List.rev a }
    | f=STRING 	a=arguments 			     		    { f, None, List.rev a }
				   
      arguments:
    | arg_list = delimited (LPAREN, separated_list (COMMA, argument), RPAREN) { arg_list }

     argument:
    | UNDERSCORE { Config.No_taint }
    | AT 	 { Config.Addr_taint }
    | STAR 	 { Config.Buf_taint }

      assert_rules:
    |                               { () }
    | a=assert_rule aa=assert_rules { a ; aa }

     assert_rule:
    | U EQUAL LPAREN CALL a=INT RPAREN arg=arguments { Hashtbl.replace Config.assert_untainted_functions a arg }
    | T EQUAL LPAREN CALL a=INT RPAREN arg=arguments { Hashtbl.replace Config.assert_tainted_functions a arg }
																 
     init:
    | TAINT c=tcontent 	            { None, Some c }
    | c=mcontent 	            { Some c, None }
    | c1=mcontent TAINT c2=tcontent { Some c1, Some c2 }

      mcontent:
    | m=INT 		{ Config.Content m }
    | m=INT MASK m2=INT { Config.CMask (m, m2) }
				      
     tcontent:
    | t=INT 		{ Config.Taint t }
    | t=INT MASK t2=INT { Config.TMask (t, t2) }
			