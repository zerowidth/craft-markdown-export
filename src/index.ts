import Realm from "realm";

const fs = require("fs");
const realm = new Realm({
  path: "craft.realm",
});

console.log("exporting realm to JSON");
let json: Record<string, any> = {};
for (const schema of realm.schema) {
  console.log(schema.name);
  for (const name in schema.properties) {
    const property = schema.properties[name];
    if (property.type == "list") {
      console.log(`  ${name}: ${property.objectType}[]`);
    }
    else {
      console.log(`  ${name}: ${property.type}${property.optional ? "?" : ""}`);
    }
  }
  let items: Record<string, any>[] = [];

  for (const object of realm.objects(schema.name)) {
    let item: Record<string, any> = {};
    object.entries().forEach(([key, value]) => {
      const property = schema.properties[key];
      if (property.type == "list") {
        let list = value as Realm.List<any>;
        item[key] = list.map(item => item.id);
      } else {
        item[key] = value;
      }
    });
    // console.log(item);
    items.push(item);
  }

  json[schema.name] = items;
}

fs.writeFileSync("craft.json", JSON.stringify(json, null, 2));
realm.close();
console.log("export complete");
