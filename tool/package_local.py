#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def run(cmd: list[str]) -> None:
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)


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
        artifact = f"windows_{arch}.zip"
        return target, flutter_target, candidates, artifact

    if system == "Linux":
        target = "linux"
        flutter_target = "linux"
        build_dir = Path("build/linux/x64/release/bundle") if arch == "amd64" else Path("build/linux/arm64/release/bundle")
        artifact = f"linux_{arch}.tar.gz"
        return target, flutter_target, [build_dir], artifact

    if system == "Darwin":
        target = "darwin"
        flutter_target = "macos"
        build_dir = Path("build/macos/Build/Products/Release/cpaclient.app")
        artifact = f"darwin_{arch}.tar.gz"
        return target, flutter_target, [build_dir], artifact

    raise SystemExit(f"Unsupported host OS: {system}")


def resolve_build_dir(candidates: list[Path]) -> Path:
    for item in candidates:
        if item.exists():
            return item
    checked = "\n".join(f" - {c.as_posix()}" for c in candidates)
    raise SystemExit(f"Build output not found. Checked candidates:\n{checked}")


def package_windows(build_dir: Path, artifact_path: Path) -> None:
    if artifact_path.exists():
        artifact_path.unlink()

    with tempfile.TemporaryDirectory() as tmp:
        dist = Path(tmp) / "dist"
        dist.mkdir(parents=True, exist_ok=True)

        for child in build_dir.iterdir():
            target = dist / child.name
            if child.is_dir():
                shutil.copytree(child, target, dirs_exist_ok=True)
            else:
                shutil.copy2(child, target)

        shutil.make_archive(str(artifact_path.with_suffix("")), "zip", root_dir=dist)


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and package the current host desktop target.",
    )
    parser.add_argument("--build-name", default="", help="Flutter build name")
    parser.add_argument("--build-number", default="", help="Flutter build number")
    parser.add_argument("--arch", choices=["auto", "amd64", "arm64"], default="auto", help="Package arch label")
    parser.add_argument("--skip-build", action="store_true", help="Only package existing build output")
    parser.add_argument("--output-dir", default="release", help="Output directory")
    parser.add_argument("--macos-sign-identity", default="", help="codesign identity for macOS ('-' for ad-hoc)")
    parser.add_argument("--macos-entitlements", default="", help="Optional entitlements plist for macOS signing")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    arch = detect_arch(args.arch)
    target, flutter_target, candidates, artifact = resolve_platform(arch)

    if args.macos_sign_identity and target != "darwin":
        raise SystemExit("--macos-sign-identity is only supported on macOS")
    if args.macos_entitlements and target != "darwin":
        raise SystemExit("--macos-entitlements is only supported on macOS")

    if not args.skip_build:
        cmd = ["flutter", "build", flutter_target, "--release"]
        if args.build_name:
            cmd.append(f"--build-name={args.build_name}")
        if args.build_number:
            cmd.append(f"--build-number={args.build_number}")
        run(cmd)

    build_dir = resolve_build_dir(candidates)

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
    artifact_path = output_dir / artifact

    if target == "windows":
        package_windows(build_dir, artifact_path)
    else:
        package_targz(build_dir, artifact_path)

    print(f"Packaged: {artifact_path.as_posix()}")
    print(f"Target: {target}")
    print(f"Arch: {arch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
