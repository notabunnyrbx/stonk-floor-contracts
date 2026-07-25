import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import solc from "solc";

const rootDir = process.cwd();
const sourceName = "AgentExecutor.sol";
const sourcePath = path.join(rootDir, "contracts", sourceName);
const artifactsDir = path.join(rootDir, "artifacts");
const artifactPath = path.join(artifactsDir, "AgentExecutor.json");

const input = {
  language: "Solidity",
  sources: {
    [sourceName]: {
      content: fs.readFileSync(sourcePath, "utf8")
    }
  },
  settings: {
    optimizer: {
      enabled: true,
      runs: 200
    },
    outputSelection: {
      "*": {
        "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"]
      }
    }
  }
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = output.errors ?? [];

for (const error of errors) {
  const writer = error.severity === "error" ? console.error : console.warn;
  writer(error.formattedMessage ?? error.message);
}

if (errors.some((error) => error.severity === "error")) {
  process.exit(1);
}

const contract = output.contracts?.[sourceName]?.AgentExecutor;
if (!contract?.abi || !contract?.evm?.bytecode?.object) {
  throw new Error("Compiler did not produce the AgentExecutor artifact.");
}

fs.mkdirSync(artifactsDir, { recursive: true });
fs.writeFileSync(
  artifactPath,
  `${JSON.stringify(
    {
      contractName: "AgentExecutor",
      sourceName,
      compiler: solc.version(),
      settings: input.settings,
      abi: contract.abi,
      bytecode: `0x${contract.evm.bytecode.object}`,
      deployedBytecode: `0x${contract.evm.deployedBytecode.object}`
    },
    null,
    2
  )}\n`
);

console.log(`Compiled AgentExecutor with ${solc.version()}.`);
console.log(`Wrote ${artifactPath}.`);
