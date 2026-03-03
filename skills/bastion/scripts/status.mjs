#!/usr/bin/env node
/**
 * Check Bastion health.
 * Usage: node status.mjs [URL]
 * Default: http://127.0.0.1:8420
 */
const url = process.argv[2] || "http://127.0.0.1:8420";

try {
  const res = await fetch(`${url}/health`);
  const data = await res.json();
  console.log(JSON.stringify({ reachable: true, ...data, url }));
} catch {
  console.log(JSON.stringify({ reachable: false, url }));
  process.exit(1);
}
