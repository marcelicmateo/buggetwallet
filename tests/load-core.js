// Loads the pure logic block from app/index.html so it can be tested in Node.
const fs = require("fs");
const path = require("path");

function loadCore() {
  const html = fs.readFileSync(path.join(__dirname, "..", "app", "index.html"), "utf8");
  const start = html.indexOf("/*CORE-START*/");
  const end = html.indexOf("/*CORE-END*/");
  if (start < 0 || end < 0) throw new Error("CORE markers not found in app/index.html");
  const src = html.slice(start, end);
  const names = ["parseRows", "makeIds", "autoCat", "catOf", "merchantKey", "merchantName", "setUserPatterns",
    "flatten", "computePeriod", "monthSummary", "affordability", "nextPayday", "addDays", "daysBetween", "CATS", "fnv"];
  return new Function(src + "\nreturn {" + names.join(",") + "};")();
}

module.exports = { loadCore };
