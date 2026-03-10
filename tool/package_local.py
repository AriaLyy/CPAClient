#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path


def _resolve_executable(name: str) -> str:
    candidates = [name]
    if platform.system() == "Windows":
        candidates = [name, f"{name}.exe", f"{name}.bat", f"{name}.cmd"]

    for item in candidates:
        path = shutil.which(item)
        if path:
            return path

    raise SystemExit(f"Command not found in PATH: {name}")


def run(cmd: list[str], *, extra_env: dict[str, str] | None = None) -> None:
    resolved = list(cmd)
    resolved[0] = _resolve_executable(resolved[0])

    # .bat/.cmd may require cmd.exe invocation for consistent behavior.
    if platform.system() == "Windows" and Path(resolved[0]).suffix.lower() in {".bat", ".cmd"}:
        resolved = ["cmd", "/c", *resolved]

    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    print(f"Running: {' '.join(resolved)}")
    subprocess.run(resolved, check=True, env=env)


def detect_arch(raw_arch: str) -> str:
    if raw_arch != "auto":
        return raw_arch

    machine = platform.machine().lower()
    env_arch = (os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE") or "").lower()
    candidate = env_arch or machine

    if candidate in {"x86_64", "amd64", "x64"}:
        return "amd64"
    if candidate in {"arm64", "aarch64"}:
        return "arm64"

    raise SystemExit(f"Unsupported host architecture: {candidate or machine}")


def resolve_platform(arch: str) -> tuple[str, str, list[Path], str]:
    system = platform.system()

    if system == "Windows":
        target = "windows"
        flutter_target = "windows"
        candidates = [
            Path(f"build/windows/{arch}/runner/Release"),
            Path("build/windows/arm64/runner/Release"),
            Path("build/windows/x64/runner/Release"),
            Path("build/windows/runner/Release"),
        ]
        return target, flutter_target, candidates, "zip"

    if system == "Linux":
        target = "linux"
        flutter_target = "linux"
        build_dir = Path("build/linux/x64/release/bundle") if arch == "amd64" else Path("build/linux/arm64/release/bundle")
        return target, flutter_target, [build_dir], "tar.gz"

    if system == "Darwin":
        target = "darwin"
        flutter_target = "macos"
        candidates = [
            Path("build/macos/Build/Products/Release/cpaclient.app"),
            Path("build/macos/Build/Products/Release/Runner.app"),
        ]
        return target, flutter_target, candidates, "tar.gz"

    raise SystemExit(f"Unsupported host OS: {system}")


def resolve_build_dir(candidates: list[Path]) -> Path:
    for item in candidates:
        if item.exists():
            return item
    checked = "\n".join(f" - {c.as_posix()}" for c in candidates)
    raise SystemExit(f"Build output not found. Checked candidates:\n{checked}")


def build_artifact_filename(target: str, arch: str, extension: str, build_name: str, build_number: str) -> str:
    version_suffix = ""
    if build_name and build_number:
        version_suffix = f"_v{build_name}_{build_number}"
    elif build_name:
        version_suffix = f"_v{build_name}"

    return f"{target}_{arch}{version_suffix}.{extension}"


def package_windows(build_dir: Path, artifact_path: Path) -> Path:
    exe_candidates = sorted(build_dir.glob("*.exe"))
    if not exe_candidates:
        raise SystemExit(f"No executable found in build output: {build_dir.as_posix()}")

    if artifact_path.exists():
        artifact_path.unlink()

    with zipfile.ZipFile(artifact_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for item in sorted(build_dir.rglob("*")):
            if item.is_file():
                zf.write(item, arcname=item.relative_to(build_dir))

    return artifact_path


def package_targz(build_dir: Path, artifact_path: Path) -> None:
    if artifact_path.exists():
        artifact_path.unlink()

    with tempfile.TemporaryDirectory() as tmp:
        dist = Path(tmp) / "dist"
        dist.mkdir(parents=True, exist_ok=True)

        target = dist / build_dir.name
        if build_dir.is_dir():
            shutil.copytree(build_dir, target, dirs_exist_ok=True)
        else:
            shutil.copy2(build_dir, target)

        with tarfile.open(artifact_path, "w:gz") as tar:
            for child in dist.iterdir():
                tar.add(child, arcname=child.name)


def _resolve_latest_tag_version() -> tuple[str, str] | None:
    try:
        result = subprocess.run(
            [
                "git",
                "for-each-ref",
                "--sort=-version:refname",
                "--format=%(refname:short)",
                "refs/tags/v*",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    for raw in result.stdout.splitlines():
        tag = raw.strip()
        if not tag:
            continue

        match = re.match(r"^v(\d+\.\d+\.\d+)(?:[+_](\d+))?$", tag)
        if not match:
            continue

        build_name = match.group(1)
        build_number = match.group(2) or "1"
        return build_name, build_number

    return None


def _resolve_pubspec_version() -> tuple[str, str] | None:
    pubspec = Path("pubspec.yaml")
    if not pubspec.is_file():
        return None

    for line in pubspec.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$", line.strip())
        if match:
            return match.group(1), match.group(2) or "1"

    return None


def _sync_tags_from_remote() -> bool:
    try:
        remotes = subprocess.run(
            ["git", "remote"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

    remote_list = [item.strip() for item in remotes.stdout.splitlines() if item.strip()]
    if not remote_list:
        return False

    remote = "origin" if "origin" in remote_list else remote_list[0]
    try:
        subprocess.run(["git", "fetch", remote, "--tags"], check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and package the current host desktop target.",
    )
    parser.add_argument("--build-name", default="", help="Flutter build name")
    parser.add_argument("--build-number", default="", help="Flutter build number")
    parser.add_argument(
        "--use-latest-tag-version",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Use latest git tag as version (default: true). Use --no-use-latest-tag-version to disable",
    )
    parser.add_argument("--arch", choices=["auto", "amd64", "arm64"], default="auto", help="Package arch label")
    parser.add_argument("--skip-build", action="store_true", help="Only package existing build output")
    parser.add_argument("--output-dir", default="release", help="Output directory")
    parser.add_argument("--macos-sign-identity", default="", help="codesign identity for macOS ('-' for ad-hoc)")
    parser.add_argument("--macos-entitlements", default="", help="Optional entitlements plist for macOS signing")
    parser.add_argument(
        "--allow-provisioning-updates",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Allow xcodebuild to create/update signing profiles on macOS (default: true)",
    )
    parser.add_argument(
        "--no-sign",
        action="store_true",
        help="Disable macOS code signing and provisioning (local build only)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.use_latest_tag_version:
        tag_version = _resolve_latest_tag_version()

        if not tag_version:
            if _sync_tags_from_remote():
                tag_version = _resolve_latest_tag_version()

        if tag_version:
            tag_build_name, tag_build_number = tag_version
            if not args.build_name:
                args.build_name = tag_build_name
            if not args.build_number:
                args.build_number = tag_build_number

            print(f"Resolved version from latest tag: {args.build_name}_{args.build_number}")
        else:
            pubspec_version = _resolve_pubspec_version()
            if pubspec_version:
                pubspec_build_name, pubspec_build_number = pubspec_version
                if not args.build_name:
                    args.build_name = pubspec_build_name
                if not args.build_number:
                    args.build_number = pubspec_build_number
                print(f"Fallback to pubspec version: {args.build_name}_{args.build_number}")
            else:
                raise SystemExit("No valid tag found after sync, and pubspec version is unavailable. Expected vMAJOR.MINOR.PATCH, vMAJOR.MINOR.PATCH+BUILD, or vMAJOR.MINOR.PATCH_BUILD")

    arch = detect_arch(args.arch)
    target, flutter_target, candidates, artifact_ext = resolve_platform(arch)

    if args.macos_sign_identity and target != "darwin":
        raise SystemExit("--macos-sign-identity is only supported on macOS")
    if args.macos_entitlements and target != "darwin":
        raise SystemExit("--macos-entitlements is only supported on macOS")
    if args.no_sign and target != "darwin":
        raise SystemExit("--no-sign is only supported on macOS")

    if not args.skip_build:
        if target == "darwin" and args.no_sign:
            cmd = ["flutter", "build", flutter_target, "--release"]
            if args.build_name:
                cmd.append(f"--build-name={args.build_name}")
            if args.build_number:
                cmd.append(f"--build-number={args.build_number}")
            run(
                cmd,
                extra_env={
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGNING_REQUIRED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "EXPANDED_CODE_SIGN_IDENTITY": "",
                    "DEVELOPMENT_TEAM": "",
                },
            )
        elif target == "darwin" and args.allow_provisioning_updates:
            flutter_config_cmd = ["flutter", "build", flutter_target, "--release", "--config-only"]
            if args.build_name:
                flutter_config_cmd.append(f"--build-name={args.build_name}")
            if args.build_number:
                flutter_config_cmd.append(f"--build-number={args.build_number}")
            run(flutter_config_cmd)

            xcode_cmd = [
                "xcodebuild",
                "-workspace",
                "macos/Runner.xcworkspace",
                "-scheme",
                "Runner",
                "-configuration",
                "Release",
                "-derivedDataPath",
                "build/macos",
                "-destination",
                "platform=macOS",
                "-allowProvisioningUpdates",
                "build",
            ]
            run(xcode_cmd)
        else:
            cmd = ["flutter", "build", flutter_target, "--release"]
            if args.build_name:
                cmd.append(f"--build-name={args.build_name}")
            if args.build_number:
                cmd.append(f"--build-number={args.build_number}")
            run(cmd)

    build_dir = resolve_build_dir(candidates)

    if target == "darwin" and args.no_sign:
        run(["codesign", "--force", "--deep", "--sign", "-", str(build_dir)])

    if target == "darwin" and args.macos_sign_identity:
        if args.macos_entitlements and not Path(args.macos_entitlements).is_file():
            raise SystemExit(f"Entitlements file not found: {args.macos_entitlements}")

        sign_cmd = [
            "codesign",
            "--force",
            "--deep",
            "--timestamp",
            "--sign",
            args.macos_sign_identity,
        ]
        if args.macos_entitlements:
            sign_cmd += ["--entitlements", args.macos_entitlements]
        sign_cmd.append(str(build_dir))
        run(sign_cmd)

        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(build_dir)])

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    artifact_name = build_artifact_filename(
        target=target,
        arch=arch,
        extension=artifact_ext,
        build_name=args.build_name,
        build_number=args.build_number,
    )
    artifact_path = output_dir / artifact_name

    if target == "windows":
        package_windows(build_dir, artifact_path)
        print(f"Packaged: {artifact_path.as_posix()}")
    else:
        package_targz(build_dir, artifact_path)
        print(f"Packaged: {artifact_path.as_posix()}")

    print(f"Target: {target}")
    print(f"Arch: {arch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
