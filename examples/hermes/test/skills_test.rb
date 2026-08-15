# frozen_string_literal: true

# Plain-ruby test harness for the skills milestone.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/skill_store"
require_relative "#{ROOT}/write_approval"
require_relative "#{ROOT}/tools/skills_list"
require_relative "#{ROOT}/tools/skill_view"
require_relative "#{ROOT}/tools/skill_manage"
require_relative "#{ROOT}/middleware/skills"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError => e
  $failures << name
  puts "FAIL  #{name}: #{e.message}"
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def assert_eq(exp, act, msg = nil)
  raise(msg || "expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def fresh_dir
  Dir.mktmpdir("hermes-skills-test")
end

def make_skill(root, category, name, body: "Do the thing.\n", description: "Does things.", extra_frontmatter: "")
  dir = File.join(root, category, name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "SKILL.md"), <<~MD)
    ---
    name: #{name}
    description: #{description}
    #{extra_frontmatter}
    ---

    #{body}
  MD
  dir
end

def reset_gate!
  Hermes::WriteApproval.flags.clear
  Hermes::WriteApproval.approval_callback = nil
  Hermes::WriteApproval.current_origin = "foreground"
end

puts "discovery + index"
test "discovers skills with categories, sorted" do
  d = fresh_dir
  make_skill(d, "mlops", "axolotl")
  make_skill(d, "github", "pr-review")
  store = Hermes::SkillStore.new(dirs: [d])
  all = store.all
  assert_eq 2, all.size
  assert_eq %w[github mlops], all.map { |e| e[:category] }
  assert store.find("axolotl")
end

test "first dir wins on name collision" do
  d1, d2 = fresh_dir, fresh_dir
  make_skill(d1, "a", "same", description: "local one")
  make_skill(d2, "b", "same", description: "shadowed one")
  store = Hermes::SkillStore.new(dirs: [d1, d2])
  assert_eq "local one", store.find("same")[:description]
end

test "platform gating hides non-matching skills" do
  d = fresh_dir
  make_skill(d, "a", "windows-only", extra_frontmatter: "metadata:\n  platforms: [windows]")
  make_skill(d, "a", "everywhere")
  store = Hermes::SkillStore.new(dirs: [d])
  names = store.all.map { |e| e[:name] }
  assert names.include?("everywhere")
  assert !names.include?("windows-only"), "windows-only skill visible on #{store.host_platform}"
end

test "index renders hermes prose, grouped lines, footer" do
  d = fresh_dir
  make_skill(d, "mlops", "axolotl", description: "Fine-tune models.")
  mw = Hermes::Middleware::Skills.new(->(env) { env }, dirs: [d])
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  mw.call(env)
  prompt = env[:metadata][:skills_prompt]
  assert prompt.include?("## Skills (mandatory)")
  assert prompt.include?("<available_skills>")
  assert prompt.include?("  mlops:")
  assert prompt.include?("    - axolotl: Fine-tune models.")
  assert prompt.include?("Only proceed without loading a skill")
end

test "empty skill dir yields no skills_prompt (slot omitted)" do
  d = fresh_dir
  mw = Hermes::Middleware::Skills.new(->(env) { env }, dirs: [d])
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  mw.call(env)
  assert env[:metadata][:skills_prompt].nil?
end

puts "skills_list / skill_view"
test "skills_list returns minimal metadata + hint" do
  d = fresh_dir
  make_skill(d, "mlops", "axolotl")
  r = JSON.parse(HermesTools::SkillsList.new(Hermes::SkillStore.new(dirs: [d])).call({}))
  assert r["success"]
  assert_eq 1, r["count"]
  assert_eq "axolotl", r["skills"].first["name"]
  assert r["hint"].include?("skill_view")
end

test "skill_view returns content + linked_files and bumps telemetry" do
  d = fresh_dir
  dir = make_skill(d, "mlops", "axolotl", body: "Full body here.")
  FileUtils.mkdir_p(File.join(dir, "references"))
  File.write(File.join(dir, "references", "api.md"), "API notes")
  store = Hermes::SkillStore.new(dirs: [d])
  r = JSON.parse(HermesTools::SkillView.new(store).call("name" => "axolotl"))
  assert r["success"]
  assert r["content"].include?("Full body here.")
  assert_eq ["references/api.md"], r["linked_files"]
  assert_eq 1, store.usage_record("axolotl")["view_count"]
end

test "skill_view file_path reads support files; traversal refused" do
  d = fresh_dir
  dir = make_skill(d, "mlops", "axolotl")
  FileUtils.mkdir_p(File.join(dir, "references"))
  File.write(File.join(dir, "references", "api.md"), "API notes")
  view = HermesTools::SkillView.new(Hermes::SkillStore.new(dirs: [d]))
  r = JSON.parse(view.call("name" => "axolotl", "file_path" => "references/api.md"))
  assert r["content"].include?("API notes")
  bad = JSON.parse(view.call("name" => "axolotl", "file_path" => "../../etc/passwd"))
  assert !bad["success"]
  assert bad["error"].include?("within the skill directory")
end

test "repeat view returns a dedup stub" do
  d = fresh_dir
  make_skill(d, "mlops", "axolotl", body: "Same body.")
  view = HermesTools::SkillView.new(Hermes::SkillStore.new(dirs: [d]))
  r1 = JSON.parse(view.call("name" => "axolotl"))
  r2 = JSON.parse(view.call("name" => "axolotl"))
  assert r1["content"].include?("Same body")
  assert r2["deduped"], "second view should be a stub"
  assert !r2.key?("content")
end

puts "skill_manage"
test "create → view round-trip with provenance-free foreground origin" do
  reset_gate!
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  manage = HermesTools::SkillManage.new(store)
  r = JSON.parse(manage.call("action" => "create", "name" => "my-skill", "content" => "---\ndescription: Mine.\n---\n\nBody.\n"))
  assert r["success"], r.inspect
  assert store.find("my-skill")
  assert store.usage_record("my-skill")["created_by"].nil?, "foreground create must not mark curator provenance"
end

test "background create marks created_by: agent" do
  reset_gate!
  Hermes::WriteApproval.current_origin = "background_review"
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  r = JSON.parse(HermesTools::SkillManage.new(store).call("action" => "create", "name" => "fork-skill", "content" => "---\ndescription: Fork.\n---\n\nB\n"))
  assert r["success"], r.inspect
  assert store.curator_managed?("fork-skill")
end

test "patch find/replace, replace_all, and no-match error" do
  reset_gate!
  d = fresh_dir
  make_skill(d, "a", "patchme", body: "foo and foo")
  manage = HermesTools::SkillManage.new(Hermes::SkillStore.new(dirs: [d]))
  ambiguous = JSON.parse(manage.call("action" => "patch", "name" => "patchme", "old_string" => "foo", "new_string" => "bar"))
  assert !ambiguous["success"], "ambiguous patch should refuse"
  all = JSON.parse(manage.call("action" => "patch", "name" => "patchme", "old_string" => "foo", "new_string" => "bar", "replace_all" => true))
  assert all["success"], all.inspect
  none = JSON.parse(manage.call("action" => "patch", "name" => "patchme", "old_string" => "zzz", "new_string" => "q"))
  assert !none["success"]
  assert_eq 1, Hermes::SkillStore.new(dirs: [d]).usage_record("patchme")["patch_count"]
end

test "write_file + remove_file support files with containment" do
  reset_gate!
  d = fresh_dir
  make_skill(d, "a", "files")
  store = Hermes::SkillStore.new(dirs: [d])
  manage = HermesTools::SkillManage.new(store)
  w = JSON.parse(manage.call("action" => "write_file", "name" => "files", "file_path" => "references/x.md", "file_content" => "notes"))
  assert w["success"], w.inspect
  bad = JSON.parse(manage.call("action" => "write_file", "name" => "files", "file_path" => "../escape.md", "file_content" => "x"))
  assert !bad["success"]
  rm = JSON.parse(manage.call("action" => "remove_file", "name" => "files", "file_path" => "references/x.md"))
  assert rm["success"]
end

puts "protection matrix + guards"
test "background fork cannot patch a user-owned skill" do
  reset_gate!
  Hermes::WriteApproval.current_origin = "background_review"
  d = fresh_dir
  make_skill(d, "a", "user-skill")
  r = JSON.parse(HermesTools::SkillManage.new(Hermes::SkillStore.new(dirs: [d])).call(
    "action" => "patch", "name" => "user-skill", "old_string" => "Do", "new_string" => "Done"))
  assert !r["success"]
  assert r["error"].include?("curator-managed"), r["error"]
end

test "background fork CAN patch a curator-managed skill" do
  reset_gate!
  Hermes::WriteApproval.current_origin = "background_review"
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_skill(d, "a", "agent-skill")
  store.set_provenance("agent-skill", created_by: "agent")
  r = JSON.parse(HermesTools::SkillManage.new(store).call(
    "action" => "patch", "name" => "agent-skill", "old_string" => "Do the thing.", "new_string" => "Done properly."))
  assert r["success"], r.inspect
end

test "background delete without absorbed_into is refused (fail closed)" do
  reset_gate!
  Hermes::WriteApproval.current_origin = "background_review"
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_skill(d, "a", "doomed")
  store.set_provenance("doomed", created_by: "agent")
  r = JSON.parse(HermesTools::SkillManage.new(store).call("action" => "delete", "name" => "doomed"))
  assert !r["success"]
  assert r["error"].include?("absorbed_into")
  assert store.find("doomed"), "skill deleted despite guard"
end

test "background delete with a real umbrella succeeds" do
  reset_gate!
  Hermes::WriteApproval.current_origin = "background_review"
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_skill(d, "a", "doomed")
  make_skill(d, "a", "umbrella")
  store.set_provenance("doomed", created_by: "agent")
  r = JSON.parse(HermesTools::SkillManage.new(store).call("action" => "delete", "name" => "doomed", "absorbed_into" => "umbrella"))
  assert r["success"], r.inspect
  assert !store.find("doomed")
end

test "pinned delete is refused even in the foreground" do
  reset_gate!
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_skill(d, "a", "pinned-one")
  store.mutate_usage("pinned-one") { |r| r["pinned"] = true }
  r = JSON.parse(HermesTools::SkillManage.new(store).call("action" => "delete", "name" => "pinned-one"))
  assert !r["success"]
  assert r["error"].include?("pinned")
end

test "write gate stages skills writes when enabled" do
  reset_gate!
  Hermes::WriteApproval.flags["skills"] = true
  d = fresh_dir
  Hermes::WriteApproval.pending_root = File.join(d, "pending")
  store = Hermes::SkillStore.new(dirs: [d])
  r = JSON.parse(HermesTools::SkillManage.new(store).call("action" => "create", "name" => "gated-skill", "content" => "---\ndescription: G.\n---\n\nB\n"))
  assert r["staged"], r.inspect
  assert !store.find("gated-skill"), "staged create wrote the skill"
  rec = Hermes::WriteApproval.get_pending("skills", r["pending_id"])
  assert rec && rec["payload"]["name"] == "gated-skill"
end

puts "middleware wiring"
test "installs the three tools and the skills_prompt metadata" do
  d = fresh_dir
  make_skill(d, "a", "wired")
  mw = Hermes::Middleware::Skills.new(->(env) { env }, dirs: [d])
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  mw.call(env)
  names = env[:provided_tools].map { |t| t.name }
  assert_eq %w[skills_list skill_view skill_manage], names
  assert env[:metadata][:skills_prompt].include?("wired")
  assert env[:skill_store]
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
