"""Security floor for the python_builder stage of the Dockerfile.

PIP_PREFER_BINARY lets pip settle for a pre-built riscv64 wheel that trails
PyPI's newest release. This keeps that lag from ever shipping a known, already
fixed vulnerability: the venv is audited with pip-audit, and every vulnerable
distribution is lifted to the release that fixes it — a wheel from RISE if one
exists, compiled from the sdist otherwise.

It fails closed: if the audit cannot run, or an installable fix does not end
up installed, the build stops. The one case it lets through, loudly, is a fix
that does not fit alongside the rest of the stack; a plain PyPI build could
hit the same constraint.

Run it with the interpreter of a throwaway venv that has pip-audit installed.
The venv it audits and upgrades is $VIRTUAL_ENV; the requirement set it
re-resolves is /opt/build/requirements.txt.
"""

import json
import os
import subprocess
import sys
import tempfile

from packaging.version import InvalidVersion, Version

TARGET = os.environ["VIRTUAL_ENV"]
REQUIREMENTS = "/opt/build/requirements.txt"
PIP_AUDIT = os.path.join(os.path.dirname(sys.executable), "pip-audit")


def log(message):
    print(f"security-floor: {message}", flush=True)


def fail(message):
    sys.exit(f"security-floor: ERROR: {message}")


def parse_version(text, what):
    try:
        return Version(text)
    except InvalidVersion:
        fail(f"cannot parse version {text!r} of {what}")


def audit():
    """Vulnerable distributions as {name: (installed, [(vuln id, [newer fixes])])}.

    pip-audit's JSON output is {"dependencies": [...], "fixes": [...]}, always
    written once the audit completes — including when nothing is vulnerable,
    since the JSON format is a "manifest" format (pip_audit._format.json).
    --strict turns a dependency it cannot resolve, or a vulnerability service
    it cannot reach, into a fatal error instead of a silent skip; a fatal error
    exits before that output file is ever opened for writing (pip_audit._cli:
    _fatal() only logs and calls sys.exit). So a missing or unparseable report
    reliably means the audit did not complete, whatever pip-audit's own exit
    status was — which is otherwise ambiguous between "vulnerabilities found"
    and "failed" (both are exit status 1).
    """
    site_packages = subprocess.run(
        [os.path.join(TARGET, "bin", "python"), "-c",
         "import sysconfig; print(sysconfig.get_path('purelib'))"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        report = os.path.join(tmp, "audit.json")
        status = subprocess.run([
            PIP_AUDIT, "--path", site_packages, "--strict",
            "--progress-spinner", "off", "--format", "json", "--output", report,
        ]).returncode
        try:
            with open(report) as f:
                data = json.load(f)
        except (OSError, ValueError):
            fail(f"pip-audit produced no report (exit status {status})")
    found = {}
    for dep in data.get("dependencies", []):
        if not dep.get("vulns"):
            continue  # also true for a skipped dependency, which has no "vulns" key
        installed = parse_version(dep["version"], dep["name"])
        vulns = []
        for vuln in dep["vulns"]:
            fixes = (parse_version(v, vuln["id"]) for v in vuln.get("fix_versions", []))
            vulns.append((vuln["id"], sorted(v for v in fixes if v > installed)))
        found[dep["name"]] = (installed, vulns)
    return found


def floors(found):
    """{name: lowest release that fixes every fixable vulnerability of it}."""
    result = {}
    for name, (installed, vulns) in sorted(found.items()):
        for vuln_id, fixes in vulns:
            if fixes:
                log(f"{name} {installed}: {vuln_id}, fixed in {fixes[0]}")
                result[name] = max(result.get(name, fixes[0]), fixes[0])
            else:
                log(f"WARNING: {name} {installed}: {vuln_id}, no fixed release yet")
    return result


def try_install(specs):
    """Real (non-dry-run) install attempt; True only if it actually succeeded.

    Never a partial success: pip's resolver settles the whole set before
    installing anything, so a failure here changes nothing in the venv.
    """
    result = subprocess.run(
        [os.path.join(TARGET, "bin", "pip"), "install", "-r", REQUIREMENTS, *specs]
    )
    return result.returncode == 0


def install_floors(wanted):
    """Install as many of {name: spec} together as will really co-install.

    Tries everything at once first (the common case, since these come from
    unrelated packages). If that fails, accepts specs one at a time, each
    verified by an actual install on top of whatever was already accepted —
    never by a spec's own isolated resolvability, which proves nothing about
    installing it alongside the others. Repeats passes until one adds nothing,
    so an ordering-sensitive pair (A only installs once B already has) still
    resolves. Returns the accepted subset; everything already installed by the
    time this returns.
    """
    if try_install(list(wanted.values())):
        return dict(wanted)
    fixed = {}
    progress = True
    while progress:
        progress = False
        for name, spec in wanted.items():
            if name not in fixed and try_install([*fixed.values(), spec]):
                fixed[name] = spec
                progress = True
    return fixed


def main():
    wanted = {name: f"{name}>={version}" for name, version in floors(audit()).items()}
    if not wanted:
        log("no known vulnerabilities with a released fix")
        return

    fixed = install_floors(wanted)
    blocked = {name: spec for name, spec in wanted.items() if name not in fixed}
    if fixed:
        log("installed " + " ".join(sorted(fixed.values())))
    for name, spec in sorted(blocked.items()):
        log(f"WARNING: {spec} does not fit alongside the rest of the stack "
            "(a plain PyPI build could hit the same constraint); left as is")

    remaining = floors(audit()).keys() - blocked.keys()
    if remaining:
        fail("still vulnerable after the upgrade: " + ", ".join(sorted(remaining)))
    log("no known vulnerabilities remain unfixed")


if __name__ == "__main__":
    main()
