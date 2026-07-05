#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require "yaml"

ROOT = File.expand_path(__dir__)
SCHEMA = JSON.parse(File.read(File.join(ROOT, "contracts-v1.schema.json")))
DEFS = SCHEMA.fetch("$defs")

def load_yaml(name)
  YAML.safe_load(File.read(File.join(ROOT, name)), aliases: true)
end

def resolve(schema)
  ref = schema["$ref"]
  return schema unless ref

  name = ref.delete_prefix("#/$defs/")
  DEFS.fetch(name)
end

def type_match?(value, type)
  case type
  when "object" then value.is_a?(Hash)
  when "array" then value.is_a?(Array)
  when "string" then value.is_a?(String)
  when "integer" then value.is_a?(Integer)
  when "number" then value.is_a?(Numeric)
  when "boolean" then value == true || value == false
  when "null" then value.nil?
  else false
  end
end

def validate(value, raw_schema, path = "$")
  schema = resolve(raw_schema)
  errors = []

  if schema["oneOf"]
    matches = schema["oneOf"].count { |branch| validate(value, branch, path).empty? }
    return ["#{path}: expected exactly one oneOf branch, matched #{matches}"] unless matches == 1
  end

  if schema["allOf"]
    schema["allOf"].each { |branch| errors.concat(validate(value, branch, path)) }
  end

  errors << "#{path}: expected const #{schema["const"].inspect}" if schema.key?("const") && value != schema["const"]
  errors << "#{path}: not in enum" if schema["enum"] && !schema["enum"].include?(value)

  if schema["type"]
    types = Array(schema["type"])
    return errors + ["#{path}: expected #{types.join(" or ")}, got #{value.class}"] unless types.any? { |t| type_match?(value, t) }
  end

  if value.is_a?(Hash)
    required = schema.fetch("required", [])
    required.each { |key| errors << "#{path}: missing #{key}" unless value.key?(key) }
    properties = schema.fetch("properties", {})
    value.each do |key, child|
      if properties[key]
        errors.concat(validate(child, properties[key], "#{path}.#{key}"))
      elsif schema["additionalProperties"] == false
        errors << "#{path}: unexpected property #{key}"
      elsif schema["additionalProperties"].is_a?(Hash)
        errors.concat(validate(child, schema["additionalProperties"], "#{path}.#{key}"))
      end
    end
  elsif value.is_a?(Array)
    errors << "#{path}: fewer than #{schema["minItems"]} items" if schema["minItems"] && value.length < schema["minItems"]
    errors << "#{path}: more than #{schema["maxItems"]} items" if schema["maxItems"] && value.length > schema["maxItems"]
    errors << "#{path}: items are not unique" if schema["uniqueItems"] && value.uniq.length != value.length
    schema.fetch("prefixItems", []).each_with_index do |child_schema, index|
      errors.concat(validate(value[index], child_schema, "#{path}[#{index}]")) if index < value.length
    end
    if schema["items"]
      value.each_with_index { |child, index| errors.concat(validate(child, schema["items"], "#{path}[#{index}]")) }
    end
  elsif value.is_a?(Numeric)
    errors << "#{path}: below minimum" if schema["minimum"] && value < schema["minimum"]
    errors << "#{path}: above maximum" if schema["maximum"] && value > schema["maximum"]
    errors << "#{path}: not above exclusiveMinimum" if schema["exclusiveMinimum"] && value <= schema["exclusiveMinimum"]
  elsif value.is_a?(String)
    errors << "#{path}: shorter than minLength" if schema["minLength"] && value.length < schema["minLength"]
    if schema["format"] == "date-time"
      begin
        Time.iso8601(value)
      rescue ArgumentError
        errors << "#{path}: invalid date-time"
      end
    end
  end

  errors
end

def assert(condition, message, errors)
  errors << "semantic: #{message}" unless condition
end

profile = load_yaml("policy-profile-v1.yaml")
manifests = load_yaml("phase-a-route-manifests-v1.yaml")
goldens = load_yaml("golden-scenarios-v1.yaml")

errors = []
errors.concat(validate(profile, DEFS.fetch("PolicyProfile"), "profile"))
errors.concat(validate(manifests, DEFS.fetch("RouteManifestSet"), "manifests"))
errors.concat(validate(goldens, DEFS.fetch("GoldenSuite"), "goldens"))

slots = profile.dig("search", "optional_slots").values.sum
assert(slots == profile.dig("search", "optional_chain_limit"), "optional slots must equal chain limit", errors)
assert(
  profile.dig("capacity", "unattended_overrun_alpha") <= profile.dig("capacity", "attended_overrun_alpha"),
  "unattended alpha must be no greater than attended alpha",
  errors
)
assert(profile.dig("capacity", "phase_a_autonomous_concurrency_cap") == 1, "Phase A concurrency must be one", errors)

route = manifests.fetch("routes").find { |item| item["route_id"] == "codex-phase-a-v1" }
assert(!route.nil?, "canonical Phase-A route is missing", errors)
if route
  risk = route.fetch("static_risk_class")
  assert(risk["resumable"], "Phase-A route must be resumable", errors)
  assert(
    risk["minimum_acceptable_output_probability"] >= profile.dig("route_risk", "unattended_minimum_acceptable_probability"),
    "Phase-A route misses acceptable-output floor",
    errors
  )
  assert(
    risk["maximum_unattended_attention_probability"] <= profile.dig("route_risk", "unattended_max_attention_probability"),
    "Phase-A route exceeds unattended-attention ceiling",
    errors
  )
end

required_scenarios = %w[
  fragmented-before-meeting
  stale-attention-does-not-interrupt
  phase-a-launch-needs-review-window
  phase-a-single-launch-bundle
  known-recovery-due
  provider-exhaustion-not-overridable
  value-provisional-until-post-integration
  dst-fold-is-one-utc-plan
  equal-candidates-use-stable-card-id
]
scenario_ids = goldens.fetch("scenarios").map { |scenario| scenario.fetch("id") }
assert(scenario_ids.sort == required_scenarios.sort, "golden scenario set differs from required set", errors)

goldens.fetch("scenarios").each do |scenario|
  input = scenario.fetch("input")
  expected = scenario.fetch("expected")
  snapshot_id = input.fetch("snapshot").fetch("snapshot_id")
  assert(expected.fetch("plan").fetch("snapshot_id") == snapshot_id, "#{scenario["id"]}: plan snapshot mismatch", errors)
  assert(expected.fetch("trace").fetch("snapshot_id") == snapshot_id, "#{scenario["id"]}: trace snapshot mismatch", errors)
  assert(
    expected.fetch("recommendation").fetch("trace_id") == expected.fetch("trace").fetch("trace_id"),
    "#{scenario["id"]}: recommendation trace mismatch",
    errors
  )
end

launch = goldens.fetch("scenarios").find { |scenario| scenario["id"] == "phase-a-single-launch-bundle" }
if launch
  nodes = launch.dig("expected", "plan", "nodes")
  reservation_types = nodes.map { |node| node["reservation_type"] }.compact
  %w[workspace quota review integration post_verify].each do |required_type|
    assert(reservation_types.include?(required_type), "launch bundle missing #{required_type} reservation", errors)
  end
end

if ARGV.first
  actual = YAML.safe_load(File.read(ARGV.first), aliases: true)
  actual_by_id = actual.fetch("scenarios").to_h { |scenario| [scenario.fetch("id"), scenario.fetch("actual")] }
  goldens.fetch("scenarios").each do |scenario|
    id = scenario.fetch("id")
    assert(actual_by_id[id] == scenario.fetch("expected"), "#{id}: actual output differs from golden", errors)
  end
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "contracts valid: profile, route manifest, #{scenario_ids.length} golden scenarios"
