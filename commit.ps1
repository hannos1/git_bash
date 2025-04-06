<#
.SYNOPSIS
  交互式 Git 补丁应用与提交管理脚本（增强版）

.DESCRIPTION
  增强功能：
  1. 支持自定义目标分支和补丁目录
  2. 更完善的错误处理和恢复机制
  3. 增强的日志输出和用户指导
  4. 支持批量处理多个补丁文件
#>

param(
    [string]$TargetBranch = "main",
    [string]$TempBranch = "temp/patch-application",
    [string]$PatchesDirectory = "./gitcommits"
)

# 初始化配置
$ErrorActionPreference = "Stop"
$global:OriginalBranch = git branch --show-current

function Write-Info {
    param([string]$message)
    Write-Host "[INFO] $message" -ForegroundColor Cyan
}

function Write-Error {
    param([string]$message)
    Write-Host "[ERROR] $message" -ForegroundColor Red
}

function Restore-OriginalState {
    Write-Info "正在恢复原始状态..."
    if ($global:OriginalBranch) {
        git checkout $global:OriginalBranch 2>&1 | Out-Null
        git branch -D $TempBranch 2>&1 | Out-Null
    }
}

function Assert-OnTargetBranch {
    $currentBranch = git branch --show-current
    if ($currentBranch -ne $TargetBranch) {
        Write-Error "当前分支 '$currentBranch' 不是目标分支 '$TargetBranch'"
        Write-Host "请先切换到目标分支或使用参数指定: -TargetBranch <分支名>" -ForegroundColor Yellow
        exit 1
    }
}

function Assert-PatchesExist {
    if (-not (Test-Path -Path $PatchesDirectory -PathType Container)) {
        Write-Error "补丁目录不存在: $PatchesDirectory"
        exit 1
    }

    $patchFiles = @(Get-ChildItem -Path $PatchesDirectory -Filter "*.patch" -File)
    if ($patchFiles.Count -eq 0) {
        Write-Error "目录中未找到 .patch 文件: $PatchesDirectory"
        exit 1
    }

    Write-Info "找到 $($patchFiles.Count) 个补丁文件"
    return $patchFiles
}

function Apply-PatchesToTempBranch {
    param([array]$PatchFiles)

    try {
        Write-Info "正在创建临时分支: $TempBranch <- $TargetBranch"
        git checkout -b $TempBranch
        
        foreach ($patch in $PatchFiles) {
            Write-Info "正在应用补丁: $($patch.Name)"
            git am -k $patch.FullName
            
            if (-not $?) {
                Write-Error "补丁应用失败: $($patch.Name)"
                Write-Host "`n请按以下步骤操作：" -ForegroundColor Yellow
                Write-Host "1. 手动解决冲突文件" -ForegroundColor Cyan
                Write-Host "2. 执行 git add/rm <file> 标记已解决的文件" -ForegroundColor Cyan
                Write-Host "3. 执行 git am --continue 继续应用补丁" -ForegroundColor Cyan
                Write-Host "4. 或执行 git am --skip 跳过此补丁" -ForegroundColor Yellow
                
                # 等待用户手动解决
                do {
                    $action = Read-Host "`n输入操作 (continue/skip/abort)"
                    switch ($action.ToLower()) {
                        "continue" {
                            git am --continue
                            if ($?) { 
                                Write-Host "补丁应用已继续" -ForegroundColor Green
                                break 
                            }
                        }
                        "skip" {
                            git am --skip
                            Write-Host "已跳过当前补丁" -ForegroundColor Yellow
                            break
                        }
                        "abort" {
                            throw "用户中止补丁应用"
                        }
                        default {
                            Write-Host "请输入有效命令 (continue/skip/abort)" -ForegroundColor Red
                        }
                    }
                } while ($true)
            }
            
            Write-Host "补丁应用成功: $($patch.Name)" -ForegroundColor Green
        }
    }
    catch {
        Restore-OriginalState
        throw
    }
}

function Invoke-InteractiveCherryPick {
    $commits = @(git log --reverse --pretty=format:"%H" "$TargetBranch..$TempBranch")
    
    if ($commits.Count -eq 0) {
        Write-Host "没有需要移植的提交" -ForegroundColor Yellow
        return
    }

    Write-Info "即将移植 $($commits.Count) 个提交到 $TargetBranch"

    foreach ($commit in $commits) {
        $commitMsg = git log -1 --pretty=format:"%s" $commit
        Write-Info "正在处理提交: ${commit} (${commitMsg})"

        git cherry-pick $commit
        if (-not $?) {
            Write-Error "提交移植失败: ${commit}"
            Write-Host "请解决冲突后执行: git cherry-pick --continue" -ForegroundColor Cyan
            throw "操作中止"
        }

        Show-InteractiveMenu -Commit $commit
    }
}

function Show-InteractiveMenu {
    param([string]$Commit)

    while ($true) {
        Write-Host "`n当前提交: $Commit" -ForegroundColor Green
        Write-Host "请选择操作:"
        Write-Host "  1) 继续下一个提交"
        Write-Host "  2) 修改当前提交 (amend)"
        Write-Host "  3) 添加文件并修改提交"
        Write-Host "  4) 执行任意 Git 命令"
        Write-Host "  5) 查看提交差异"
        Write-Host "  6) 终止操作"
        
        $choice = Read-Host "选择 (1-6)"
        switch ($choice) {
            1 { return }
            2 { 
                git commit --amend --no-edit 
                Write-Host "提交已修改" -ForegroundColor Green
            }
            3 {
                $files = Read-Host "输入要添加的文件(空格分隔)"
                git add $files.Split()
                git commit --amend --no-edit
                Write-Host "文件已添加并修改提交" -ForegroundColor Green
            }
            4 {
                Write-Host "输入 Git 命令(不含'git'前缀)，输入'exit'返回"
                while ($true) {
                    $cmd = Read-Host "git"
                    if ($cmd -eq "exit") { break }
                    Invoke-Expression "git $cmd"
                }
            }
            5 {
                git show $Commit
            }
            6 { 
                Restore-OriginalState
                exit 0 
            }
            default { Write-Host "无效选择" -ForegroundColor Red }
        }
    }
}

# 主执行流程
try {
    # 验证环境
    Assert-OnTargetBranch
    $patchFiles = Assert-PatchesExist

    # 应用补丁
    Apply-PatchesToTempBranch -PatchFiles $patchFiles

    # 交互式移植提交
    Invoke-InteractiveCherryPick

    # 清理临时分支
    git checkout $TargetBranch
    git branch -D $TempBranch

    Write-Host "`n操作成功完成!`n" -ForegroundColor Green
    git log --oneline -n 3 $TargetBranch
}
catch {
    Write-Error "脚本执行失败: $_"
    exit 1
}
finally {
    if ($?) {
        Write-Info "临时分支 $TempBranch 已自动删除"
    }
}