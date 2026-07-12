interface Config { verbose: boolean; level: "low" | "high"; }
declare function run(c: Config): void;
run({ verbose: true, level: "high" });
run({ verbose: true, level: "extreme" });
