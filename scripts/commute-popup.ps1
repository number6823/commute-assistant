# 이동비서 로봇 알림창: 예/아니요 버튼, 입력창, 안내문 세 가지 모드.
# 모양은 ~/.claude/hooks/greet-startup.ps1 의 로봇 알림창을 따른다.
# 결과는 stdout 한 줄로 돌려준다:
#   yesno -> "yes" | "no" | "timeout"
#   input -> 입력한 글자 (취소/시간초과면 빈 줄)
#   info  -> 아무것도 출력하지 않는다

param(
    [ValidateSet('yesno', 'input', 'info')][string]$Mode = 'info',
    [string]$Title   = '이동비서',
    [string]$Message = '',
    [string]$Sub     = '',
    [string]$Default = '',
    [string]$YesText = '예',
    [string]$NoText  = '아니요',
    [int]$Seconds    = 0      # 0 이면 모드별 기본값 (yesno/input 120초, info 60초)
)

$ErrorActionPreference = 'Stop'
if ($Seconds -le 0) { $Seconds = if ($Mode -eq 'info') { 60 } else { 120 } }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# info 모드는 포커스를 뺏지 않고, 버튼/입력창이 있는 모드는 포커스를 받아야 한다
Add-Type -WarningAction SilentlyContinue -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System.Windows.Forms;
public class CommuteForm : Form {
    public bool NoActivate = false;
    public CommuteForm() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
    protected override bool ShowWithoutActivation { get { return NoActivate; } }
}
"@

# ── 크기 / 색상 ─────────────────────────────────────────────
$W = 540
$H = 290
$C = [System.Drawing.Color]
$cyan    = $C::FromArgb(0, 229, 255)
$cyanDim = $C::FromArgb(0, 150, 170)
$bg      = $C::FromArgb(11, 15, 22)
$panel   = $C::FromArgb(20, 30, 42)
$textCol = $C::FromArgb(200, 214, 226)

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$bgBrush    = New-Object System.Drawing.SolidBrush $bg
$panelBrush = New-Object System.Drawing.SolidBrush $panel
$cyanBrush  = New-Object System.Drawing.SolidBrush $cyan
$dimBrush   = New-Object System.Drawing.SolidBrush $cyanDim
$textBrush  = New-Object System.Drawing.SolidBrush $textCol
$scanPen    = New-Object System.Drawing.Pen ($C::FromArgb(14, 0, 255, 255)), 1
$cyanPen2   = New-Object System.Drawing.Pen $cyan, 2
$glowPen    = New-Object System.Drawing.Pen ($C::FromArgb(45, 0, 229, 255)), 7
$fMono9     = New-Object System.Drawing.Font('Consolas', 9)
$fTitle     = New-Object System.Drawing.Font('맑은 고딕', 14, [System.Drawing.FontStyle]::Bold)
$fKor       = New-Object System.Drawing.Font('맑은 고딕', 10.5)
$fKorSmall  = New-Object System.Drawing.Font('맑은 고딕', 9.5)

$fmtWrap = New-Object System.Drawing.StringFormat
$fmtWrap.FormatFlags = [System.Drawing.StringFormatFlags]::LineLimit
$fmtWrap.Trimming    = [System.Drawing.StringTrimming]::EllipsisWord

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:result = ''

$form = New-Object CommuteForm
$form.NoActivate      = ($Mode -eq 'info')
$form.Text           = 'Claude Code'
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'CenterScreen'
$form.ShowInTaskbar   = $false
$form.TopMost         = $true
$form.ClientSize      = New-Object System.Drawing.Size($W, $H)
$form.BackColor       = $bg
$form.Region          = New-Object System.Drawing.Region (New-RoundPath 0 0 $W $H 16)

$tx = 152
$tw = $W - $tx - 22

$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $t = $sw.Elapsed.TotalSeconds

    $g.FillRectangle($bgBrush, 0, 0, $W, $H)
    for ($y = 0; $y -lt $H; $y += 4) { $g.DrawLine($scanPen, 0, $y, $W, $y) }

    $border = New-RoundPath 2 2 ($W - 4) ($H - 4) 14
    $g.DrawPath($glowPen, $border)
    $g.DrawPath($cyanPen2, $border)
    $border.Dispose()

    # 로봇 머리
    $g.TranslateTransform(0, 20)
    $head = New-RoundPath 28 78 96 80 14
    $g.FillPath($panelBrush, $head)
    $g.DrawPath($cyanPen2, $head)
    $head.Dispose()
    $g.FillRectangle($dimBrush, 19, 104, 9, 28)
    $g.FillRectangle($dimBrush, 124, 104, 9, 28)

    $g.DrawLine($cyanPen2, 76, 78, 76, 60)
    $pulse = [int](120 + 135 * (0.5 + 0.5 * [Math]::Sin($t * 6)))
    $ball = New-Object System.Drawing.SolidBrush ($C::FromArgb($pulse, 0, 229, 255))
    $g.FillEllipse($ball, 69, 47, 14, 14)
    $ball.Dispose()

    $eyeH = 16
    if (($t % 3.2) -lt 0.14) { $eyeH = 3 }
    $eyeY = 108 - $eyeH / 2
    $glow = New-Object System.Drawing.SolidBrush ($C::FromArgb(55, 0, 229, 255))
    foreach ($ex in 46, 84) {
        $g.FillRectangle($glow, $ex - 3, $eyeY - 3, 28, $eyeH + 6)
        $g.FillRectangle($cyanBrush, $ex, $eyeY, 22, $eyeH)
    }
    $glow.Dispose()

    for ($i = 0; $i -lt 5; $i++) {
        $bh = 3 + 9 * [Math]::Abs([Math]::Sin($t * 7 + $i * 1.3))
        $g.FillRectangle($cyanBrush, 49 + $i * 11, 146 - $bh, 7, $bh)
    }
    $g.ResetTransform()

    # 텍스트
    $g.DrawString("// COMMUTE.EXE  $Title", $fMono9, $dimBrush, $tx, 22)
    $g.DrawString($Message, $fTitle, $cyanBrush, (New-Object System.Drawing.RectangleF(($tx - 2), 46, $tw, 84)), $fmtWrap)
    if ($Sub) {
        $subH = if ($Mode -eq 'info') { 112 } else { 56 }    # 안내창은 버튼이 없어서 더 길게 쓴다 (경로 + 날씨)
        $g.DrawString($Sub, $fKorSmall, $textBrush, (New-Object System.Drawing.RectangleF($tx, 132, $tw, $subH)), $fmtWrap)
    }

    # 하단 남은 시간 바
    $remain = [Math]::Max(0, 1 - $t / $Seconds)
    $g.FillRectangle($dimBrush, 20, $H - 18, ($W - 40) * $remain, 3)
})

function New-NeonButton([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $text
    $b.Location  = New-Object System.Drawing.Point($x, $y)
    $b.Size      = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $cyan
    $b.FlatAppearance.BorderSize  = 1
    $b.BackColor = $panel
    $b.ForeColor = $cyan
    $b.Font      = $fKor
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $b
}

$btnY = 196

switch ($Mode) {
    'yesno' {
        $yes = New-NeonButton $YesText $tx $btnY 120
        $no  = New-NeonButton $NoText ($tx + 132) $btnY 120
        $yes.Add_Click({ $script:result = 'yes'; $form.Close() })
        $no.Add_Click({ $script:result = 'no'; $form.Close() })
        $form.Controls.AddRange(@($yes, $no))
    }
    'input' {
        $box = New-Object System.Windows.Forms.TextBox
        $box.Location    = New-Object System.Drawing.Point($tx, ($btnY + 2))
        $box.Size        = New-Object System.Drawing.Size(250, 30)
        $box.Font        = $fKor
        $box.BackColor   = $panel
        $box.ForeColor   = $textCol
        $box.BorderStyle = 'FixedSingle'
        $box.Text        = $Default
        $ok = New-NeonButton '확인' ($tx + 262) $btnY 90
        $submit = { $script:result = $box.Text.Trim(); $form.Close() }
        $ok.Add_Click($submit)
        $box.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $submit } })
        $form.Controls.AddRange(@($box, $ok))
        $form.Add_Shown({ $form.Activate(); $box.Focus(); $box.SelectAll() })
    }
    'info' {
        $form.Cursor = [System.Windows.Forms.Cursors]::Hand
        $form.Add_Click({ $form.Close() })
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 40
$timer.Add_Tick({
    if ($sw.Elapsed.TotalSeconds -ge $Seconds) {
        if ($Mode -eq 'yesno') { $script:result = 'timeout' }
        $form.Close()
    } else { $form.Invalidate() }
})
$timer.Start()

[void]$form.ShowDialog()
$timer.Stop()
$form.Dispose()

if ($Mode -ne 'info') { Write-Output $script:result }
