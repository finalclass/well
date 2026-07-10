module Key = struct
  type t = Obj.t
  let hash = Hashtbl.hash
  let equal = (==)
end

module Table = Hashtbl.Make (Key)

let table = Table.create 16

let load instance =
  Obj.obj (Table.find table (Obj.repr instance))

let persist instance state =
  Table.replace table (Obj.repr instance) (Obj.repr state)

let destroy instance =
  Table.remove table (Obj.repr instance)
