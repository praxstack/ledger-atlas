#!/usr/bin/env python3
"""Public CLI regression: python3 scripts/check-sync-gstack-skills.py [installer]."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(
    sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("sync-gstack-skills.sh")
).resolve()


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def snapshot(root):
    return {
        str(p.relative_to(root)): ("link", os.readlink(p))
        if p.is_symlink()
        else ("file", p.read_bytes())
        if p.is_file()
        else ("dir",)
        for p in sorted(root.rglob("*"))
    }


def fixture(base, fallback=False):
    repo, home = base / "repo", base / "home"
    vendor = base / "canonical/gstack" if fallback else repo / "vendor/skills-repos/gstack"
    script = repo / "scripts/sync-gstack-skills.sh"
    script.parent.mkdir(parents=True)
    shutil.copy2(SCRIPT, script)
    for name in (
        "gstack",
        "gstack-upgrade",
        "gstack-qa",
        "gstack-review",
        "gstack-open-gstack-browser",
    ):
        short = name.removeprefix("gstack-")
        write(
            vendor / ".cursor/skills" / name / "SKILL.md",
            f'---\nname: {short}\ndescription: test (gstack)\n---\nGSTACK_ROOT="$HOME/.cursor/skills/gstack"\n'
            '[ -x "$_SS" ] || _SS=".cursor/skills/gstack/bin/gstack-skill-start"\n',
        )
    for rel in (
        "bin/tool",
        "lib/lib.sh",
        "browse/dist/index.js",
        "browse/bin/start",
        "ETHOS.md",
        "review/checklist.md",
        "review/TODOS-format.md",
        "supabase/config.sh",
        "open-gstack-browser/asset.txt",
    ):
        write(vendor / rel, "original source\n")
    project = repo / ".agents/skills"
    cursor = home / ".cursor/skills"
    project.mkdir(parents=True)
    cursor.parent.mkdir(parents=True)
    if fallback:
        canonical = home / ".agents/skills"
        canonical.mkdir(parents=True)
        (canonical / "gstack").symlink_to(vendor, target_is_directory=True)
        cursor.symlink_to(canonical, target_is_directory=True)
    else:
        cursor.mkdir()
    blockers = base / "blockers"
    for tool in ("git", "bun"):
        write(blockers / tool, '#!/bin/sh\necho "unexpected network/generation" >&2\nexit 99\n')
        (blockers / tool).chmod(0o755)
    env = {**os.environ, "HOME": str(home), "PATH": str(blockers) + os.pathsep + os.environ["PATH"]}
    env.pop("GSTACK_DIR", None)
    env.pop("CURSOR_SKILLS_DIR", None)
    return script, env, vendor, project, cursor


def run(script, env):
    return subprocess.run(
        ["bash", str(script)], env=env, text=True, capture_output=True, timeout=20, check=False
    )


def success(result):
    assert result.returncode == 0, f"exit {result.returncode}: {result.stderr}"


def links(parent):
    for rel in ("SKILL.md", "gstack-upgrade/SKILL.md"):
        link = parent / "gstack" / rel
        assert link.is_symlink() and link.is_file(), f"unresolved runtime link: {link}"
        assert not os.path.isabs(os.readlink(link)), f"nonportable runtime link: {link}"


def fresh(base):
    script, env, vendor, project, cursor = fixture(base)
    original = snapshot(vendor)
    success(run(script, env))
    assert snapshot(vendor) == original, "source modified by sync"
    for parent in (project, cursor):
        links(parent)
        assert "name: connect-chrome\n" in (parent / "connect-chrome/SKILL.md").read_text()
        assert (parent / "qa/SKILL.md").is_file()
    assert ".agents/skills/gstack" in (project / "qa/SKILL.md").read_text()
    before = snapshot(base)
    success(run(script, env))
    assert snapshot(base) == before, "rerun is not idempotent"
    # Move the complete install, source and home together; the two runtime links survive.
    moved = base.with_name(base.name + "-moved")
    base.rename(moved)
    try:
        for parent in (project, cursor):
            links(moved / parent.relative_to(base))
    finally:
        moved.rename(base)


def preservation(base):
    script, env, vendor, project, cursor = fixture(base)
    outside = base / "outside"
    write(outside / "SKILL.md", "local alias outside tree\n")
    write(outside / "dist/keep.txt", "local runtime outside tree\n")
    for parent in (project, cursor):
        for name in ("review", "gstack-personal", "gstack-qa"):
            write(parent / name / "SKILL.md", f"name: {name}\ndescription: local (gstack) edits\n")
            write(parent / name / ".private", "keep\n")
        (parent / "connect-chrome").symlink_to(outside, target_is_directory=True)
        (parent / "gstack").mkdir()
        (parent / "gstack/browse").symlink_to(outside, target_is_directory=True)
        write(parent / "gstack/SKILL.md", "local runtime doc\n")
        write(parent / "gstack/bin/tool", "local runtime bin\n")
        (parent / "upgrade").symlink_to(base / "missing-skill", target_is_directory=True)
    protected = [(p, snapshot(p)) for p in (vendor, outside, project, cursor)]
    success(run(script, env))
    for path, before in protected:
        after = snapshot(path)
        assert all(after.get(k) == v for k, v in before.items()), (
            f"existing content changed: {path}"
        )
    before = snapshot(base)
    success(run(script, env))
    assert snapshot(base) == before, "preserved install changed on rerun"


def mirror(base):
    script, env, vendor, project, cursor = fixture(base, fallback=True)
    original = snapshot(vendor)
    success(run(script, env))
    assert snapshot(vendor) == original, "fallback canonical source changed through mirror"
    assert (cursor / "gstack").resolve() == vendor.resolve()
    links(project)
    before = snapshot(base)
    success(run(script, env))
    assert snapshot(base) == before, "mirror rerun changed content"


def runtime_resources(base):
    script, env, vendor, project, cursor = fixture(base)
    resources = (
        "review/specialists/testing.md",
        "review/design-checklist.md",
        "scripts/jargon-list.json",
        "docs/reference.md",
        "design/dist/tool",
        "office-hours/examples/sample.md",
    )
    doc = vendor / ".cursor/skills/gstack-review/SKILL.md"
    doc.write_text(doc.read_text() + "".join(f"Read $GSTACK_ROOT/{rel}\n" for rel in resources))
    for rel in resources + ("review/blocked/new.md",):
        write(vendor / rel, f"canonical {rel}\n")
    # Native docs must not override the two generated runtime doc links.
    write(vendor / "SKILL.md", "native root doc\n")
    write(vendor / "gstack-upgrade/SKILL.md", "native upgrade doc\n")
    outside = base / "outside"
    write(outside / "keep", "untouched\n")
    for parent in (project, cursor):
        write(parent / "gstack/review/checklist.md", "local checklist\n")
        write(parent / "gstack/review/specialists/local.md", "local specialist\n")
        (parent / "gstack/review/blocked").symlink_to(outside, target_is_directory=True)
    # A source alias back into the destination must not create a recursive runtime link.
    (vendor / "review/loop").symlink_to(project / "gstack/review", target_is_directory=True)
    original, external = snapshot(vendor), snapshot(outside)
    success(run(script, env))
    assert not (project / "gstack/review/loop").is_symlink()
    for parent in (project, cursor):
        installed = (parent / "review/SKILL.md").read_text()
        for rel in resources:
            assert f"$GSTACK_ROOT/{rel}" in installed
            assert (parent / "gstack" / rel).read_text() == (vendor / rel).read_text(), rel
        assert (parent / "gstack/review/checklist.md").read_text() == "local checklist\n"
        assert (parent / "gstack/review/specialists/local.md").read_text() == "local specialist\n"
        assert (parent / "gstack/SKILL.md").read_text() == (
            vendor / ".cursor/skills/gstack/SKILL.md"
        ).read_text()
        assert (parent / "gstack/gstack-upgrade/SKILL.md").read_text() == (
            vendor / ".cursor/skills/gstack-upgrade/SKILL.md"
        ).read_text()
        links(parent)
    assert snapshot(vendor) == original and snapshot(outside) == external
    before = snapshot(base)
    success(run(script, env))
    assert snapshot(base) == before, "runtime merge not idempotent"


def short_resource_references(base):
    script, env, vendor, project, cursor = fixture(base)
    references = (
        ".cursor/skills/review/checklist.md",
        ".cursor/skills/review/greptile-triage.md",
        "~/.cursor/skills/review/design-checklist.md",
        "$HOME/.cursor/skills/office-hours/examples/intro.md",
        "$_ROOT/.agents/skills/review/TODOS-format.md",
    )
    for rel in (
        "review/greptile-triage.md",
        "review/design-checklist.md",
        "office-hours/examples/intro.md",
    ):
        write(vendor / rel, "runtime resource\n")
    for name in ("gstack-review", "gstack-open-gstack-browser"):
        doc = vendor / ".cursor/skills" / name / "SKILL.md"
        doc.write_text(
            doc.read_text()
            + "".join(f"Read `{ref}`.\n" for ref in references)
            + "Keep `.cursor/skills/unrelated/local.md`.\n"
        )
    before = snapshot(vendor)
    success(run(script, env))
    for parent in (project, cursor):
        for name in ("review", "connect-chrome"):
            installed = (parent / name / "SKILL.md").read_text()
            assert 'GSTACK_ROOT="$HOME/.cursor/skills/gstack"' in installed
            assert "Keep `.cursor/skills/unrelated/local.md`." in installed
            for ref in references:
                rel = ref.split("/skills/", 1)[1]
                assert f"Read `$GSTACK_ROOT/{rel}`." in installed, (
                    f"unrouted resource: {parent}/{name}: {ref}"
                )
                assert (parent / "gstack" / rel).is_file(), rel
    assert snapshot(vendor) == before, "resource routing changed canonical docs"
    before = snapshot(base)
    success(run(script, env))
    assert snapshot(base) == before, "patched overlay rerun not idempotent"


def malformed(base):
    for n, name in enumerate(
        (".", "..", "../escaped", str(base / "escaped-absolute"), "qa/other", "bad name", "gstack")
    ):
        script, env, vendor, project, _cursor = fixture(base / str(n))
        write(vendor / ".cursor/skills/gstack-aaa/SKILL.md", f"name: {name}\n(gstack)\n")
        write(project.parent / "escaped/keep", "keep\n")
        before = snapshot(vendor)
        result = run(script, env)
        assert result.returncode != 0, f"accepted malformed name: {name!r}"
        assert "invalid" in result.stderr.lower(), (
            f"no name validation for {name!r}: {result.stderr}"
        )
        assert (project.parent / "escaped/keep").read_text() == "keep\n"
        assert snapshot(vendor) == before, f"source changed for {name!r}"


failures = []
for check in (fresh, preservation, mirror, malformed, runtime_resources, short_resource_references):
    with tempfile.TemporaryDirectory(prefix="gstack-cli-") as temp:
        try:
            check(Path(temp))
            print(f"PASS {check.__name__}")
        except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
            failures.append(check.__name__)
            print(f"FAIL {check.__name__}: {error}", file=sys.stderr)
assert not failures, f"failed CLI checks: {failures}"
