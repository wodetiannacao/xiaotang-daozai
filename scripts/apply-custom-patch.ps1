param(
    [string]$RepoRoot = '.',
    [string]$HoverIntent = '0.05',
    [string]$MinimalHoverIntent = '0.10',
    [string]$TargetRepo = 'wodetiannacao/xiaotang-daozai'
)
$ErrorActionPreference = 'Stop'

function Get-RepoPath([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = '.' }
    if (-not [IO.Path]::IsPathRooted($Root)) {
        $Root = Join-Path (Get-Location) $Root
    }
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "仓库目录不存在：$resolved"
    }
    return $resolved.TrimEnd('\', '/')
}

function Read-Utf8NoBom([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    return ([Text.UTF8Encoding]::new($false)).GetString($bytes)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Replace-ExactOnce([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $matches = [regex]::Matches($text, $Pattern)
    if ($matches.Count -ne 1) {
        throw ("{0} 在 {1} 中应恰好匹配 1 次，实际 {2} 次。" -f $Label, $Path, $matches.Count)
    }
    $updated = [regex]::Replace($text, $Pattern, $Replacement, 1)
    Write-Utf8NoBom $Path $updated
}

function Replace-AllVerified([string]$Path, [string]$Old, [string]$New, [int]$Expected, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $oldHits = [regex]::Matches($text, [regex]::Escape($Old)).Count
    $newHits = [regex]::Matches($text, [regex]::Escape($New)).Count
    if ($oldHits -eq $Expected) {
        Write-Utf8NoBom $Path $text.Replace($Old, $New)
        return
    }
    if ($Old -ne $New -and $oldHits -eq 0 -and $newHits -eq $Expected) {
        return
    }
    throw ("{0} 在 {1} 中应恰好匹配 {2} 次（当前旧值 {3} 次、新值 {4} 次）。" -f $Label, $Path, $Expected, $oldHits, $newHits)
}


function Convert-ToFileNewlines([string]$Text, [string]$Newline) {
    return $Text.Replace("`r`n", "`n").Replace("`n", $Newline)
}

function Replace-UniqueSnippet([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $text = Read-Utf8NoBom $Path
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $oldText = Convert-ToFileNewlines $Old $newline
    $newText = Convert-ToFileNewlines $New $newline
    $oldHits = [regex]::Matches($text, [regex]::Escape($oldText)).Count
    $newHits = [regex]::Matches($text, [regex]::Escape($newText)).Count
    if ($oldHits -eq 1) {
        $offset = $text.IndexOf($oldText)
        Write-Utf8NoBom $Path ($text.Substring(0, $offset) + $newText + $text.Substring($offset + $oldText.Length))
        return
    }
    if ($oldHits -eq 0 -and $newHits -eq 1) {
        return
    }
    throw ("{0} 在 {1} 中应恰好出现 1 次，实际旧值 {2} 次、新值 {3} 次。" -f $Label, $Path, $oldHits, $newHits)
}

$root = Get-RepoPath $RepoRoot
if ($TargetRepo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "TargetRepo 格式无效：$TargetRepo（应为 owner/repo）"
}
if ($HoverIntent -notmatch '^\d+\.\d+$' -or $MinimalHoverIntent -notmatch '^\d+\.\d+$') {
    throw "悬停时长必须是形如 0.05 的十进制数字。"
}

$app = Join-Path $root 'src/app.rs'
$updates = Join-Path $root 'src/updates.rs'
foreach ($path in @($app, $updates)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "找不到文件：$path"
    }
}

Replace-ExactOnce `
    -Path $app `
    -Pattern '(?m)^const HOVER_INTENT: f64 = [^;]+;' `
    -Replacement ("const HOVER_INTENT: f64 = {0};" -f $HoverIntent) `
    -Label 'HOVER_INTENT'

Replace-ExactOnce `
    -Path $app `
    -Pattern '(?m)^const MINIMAL_HOVER_INTENT: f64 = [^;]+;' `
    -Replacement ("const MINIMAL_HOVER_INTENT: f64 = {0};" -f $MinimalHoverIntent) `
    -Label 'MINIMAL_HOVER_INTENT'

$appText = Read-Utf8NoBom $app
if ($appText -notmatch '(?m)^const LEAVE_DELAY: f64 = 0\.12;' ) {
    throw "LEAVE_DELAY 被意外改动，或在 src/app.rs 中找不到原始定义。"
}
if ($appText -notmatch '(?m)^const LIFT_HOLD: f64 = 0\.12;') {
    throw "LIFT_HOLD 被意外改动，或在 src/app.rs 中找不到原始定义。"
}

$oldRepo = 'Renly1994/xiaotang-daozai'
Replace-AllVerified `
    -Path $updates `
    -Old $oldRepo `
    -New $TargetRepo `
    -Expected 3 `
    -Label '更新源仓库常量（REPOSITORY/API/RELEASES）'

$updatesText = Read-Utf8NoBom $updates
$constHits = [regex]::Matches($updatesText, ('(?m)^const (REPOSITORY|API|RELEASES): &str = "[^"]*{0}[^"]*";' -f [regex]::Escape($TargetRepo)))
if ($constHits.Count -ne 3) {
    throw ("src/updates.rs 中指向 {0} 的 REPOSITORY/API/RELEASES 常量应为 3 条，实际 {1} 条。" -f $TargetRepo, $constHits.Count)
}


$tests = Join-Path $root 'src/ui_tests.rs'
if (-not (Test-Path -LiteralPath $tests -PathType Leaf)) {
    throw "找不到文件：$tests"
}

# hover() 以 60fps 推进，elapsed = (floor(secs*60)-1)/60。
# 下面的 0.02s（1 帧）一定短于补丁后的意图缓冲，用于断言“尚未展开”。
Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(Pos2::new(WIN_W / 2.0, 12.0), 0.1);`n    assert!(h.app.progress() < 0.1, `"意图缓冲期内不应展开`");" `
    -New "    h.hover(Pos2::new(WIN_W / 2.0, 12.0), 0.02);`n    assert!(h.app.progress() < 0.1, `"意图缓冲期内不应展开`");" `
    -Label 'hover_expands_with_overshoot_and_leave_collapses 缓冲期时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(Pos2::new(WIN_W/2.0,2.0),0.25);`n    assert!(!h.app.open,`"短暂碰到刘海不能误触`");" `
    -New "    h.hover(Pos2::new(WIN_W/2.0,2.0),0.02);`n    assert!(!h.app.open,`"短暂碰到刘海不能误触`");" `
    -Label 'browser_minimal_closes_the_open_island_but_still_allows_deliberate_hover 短暂悬停时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(inside,0.25);`n    assert!(!h.app.open,`"短暂经过极简刘海不得展开`");" `
    -New "    h.hover(inside,0.02);`n    assert!(!h.app.open,`"短暂经过极简刘海不得展开`");" `
    -Label 'minimal_hover_requires_continuous_deliberate_contact 首次短暂悬停时长'

Replace-UniqueSnippet `
    -Path $tests `
    -Old "    h.hover(inside,0.25);`n    assert!(!h.app.open,`"移出刘海应重新计算停留时间`");" `
    -New "    h.hover(inside,0.02);`n    assert!(!h.app.open,`"移出刘海应重新计算停留时间`");" `
    -Label 'minimal_hover_requires_continuous_deliberate_contact 重置后短暂悬停时长'


# --- 滚轮切页惯性（0.60s）与 Shift+滚轮强制切页 ---
$wheel_constants_old = @'
const PAGE_SLIDE: f32 = 46.0;

pub struct Options {
'@
$wheel_constants_new = @'
const PAGE_SLIDE: f32 = 46.0;
/// 滚轮切页后的惯性锁定时长：这段时间内指针几乎不动则继续优先切页。
const WHEEL_PAGE_LOCK: f64 = 0.60;
/// 惯性锁定期间允许的指针抖动（窗口/画布逻辑像素），超过则立刻解锁。
const WHEEL_PAGE_LOCK_MOVE: f32 = 10.0;

pub struct Options {
'@
Replace-UniqueSnippet `
    -Path $app `
    -Old $wheel_constants_old `
    -New $wheel_constants_new `
    -Label 'WHEEL_PAGE_LOCK 常量'

$wheel_fields_old = @'
    wheel_page_at: f64,

    // 拖入
'@
$wheel_fields_new = @'
    wheel_page_at: f64,
    wheel_page_lock_until: f64,
    wheel_page_lock_pos: Option<Pos2>,

    // 拖入
'@
Replace-UniqueSnippet `
    -Path $app `
    -Old $wheel_fields_old `
    -New $wheel_fields_new `
    -Label 'App 滚轮锁定字段'

$wheel_init_old = @'
            wheel_page_at: -1.0,
            drag_hot: false,
'@
$wheel_init_new = @'
            wheel_page_at: -1.0,
            wheel_page_lock_until: -1.0,
            wheel_page_lock_pos: None,
            drag_hot: false,
'@
Replace-UniqueSnippet `
    -Path $app `
    -Old $wheel_init_old `
    -New $wheel_init_new `
    -Label 'App 滚轮锁定字段初始化'

$wheel_go_old = @'
        if page == self.page || !self.settings.visible_pages[page] { return; }
        self.music_volume_open=false;
'@
$wheel_go_new = @'
        if page == self.page || !self.settings.visible_pages[page] { return; }
        self.wheel_page_lock_until=-1.0;
        self.wheel_page_lock_pos=None;
        self.music_volume_open=false;
'@
Replace-UniqueSnippet `
    -Path $app `
    -Old $wheel_go_old `
    -New $wheel_go_new `
    -Label 'go() 清除滚轮锁定'

$wheel_handler_old = @'
        if (!self.is_editing() || self.todo_choosing) && page_hover && self.open && self.reveal > 0.95 {
            let (scroll, left, right, esc) = ctx.input(|i| (i.raw_scroll_delta.y, i.key_pressed(egui::Key::ArrowLeft), i.key_pressed(egui::Key::ArrowRight), i.key_pressed(egui::Key::Escape)));
            if esc { self.hover_lock = true; }
            if (left || right) && !self.todo_choosing {
                self.wheel_delta=0.0;
                self.navigate_page(right);
            } else if scroll!=0.0 {
                let cursor=env.cursor.unwrap()-self.content_origin(win).to_vec2();
                let mail_reading=inside && self.page==5 && self.mail.open_uid.is_some();
                let mail_list=self.page==5 && !self.mail.accounts.is_empty() && self.mail.open_uid.is_none() && self.mail_list_bounds().contains(cursor);
                let music_volume=self.page==0 && (Rect::from_min_max(Pos2::new(354.0,106.0),Pos2::new(380.0,130.0)).contains(cursor)
                    || self.music_volume_open && crate::pages::MUSIC_VOLUME_RECT.contains(cursor));
                if mail_reading || mail_list || music_volume {self.wheel_delta=0.0;}
                else {
                    // 累积高精度滚轮的小幅输入；停顿或反向时丢弃上一段余量。
                    if self.t-self.wheel_at>0.18 || self.wheel_delta*scroll<0.0 {self.wheel_delta=0.0;}
                    self.wheel_at=self.t;
                    self.wheel_delta+=scroll;
                    if self.wheel_delta.abs()>=8.0 {
                        let next=self.wheel_delta<0.0;
                        self.wheel_delta=0.0;
                        let calendar_max=if self.page==CALENDAR_PAGE {self.calendar_scroll_max(env)}else{0};
                        let calendar_body=self.page==CALENDAR_PAGE && Rect::from_min_max(Pos2::new(163.0,52.0),Pos2::new(378.0,208.0)).contains(cursor);
                        let clipboard_tab=self.page==3 && self.shelf_tab==1;
                        let clipboard_body=clipboard_tab && Rect::from_min_max(Pos2::new(42.0,31.0),Pos2::new(377.0,124.0)).contains(cursor);
                        let list=match self.page {
                            CALENDAR_PAGE if calendar_body=>Some((&mut self.calendar.view.first,calendar_max)),
                            4 if Rect::from_min_max(Pos2::new(196.0,31.0),Pos2::new(377.0,124.0)).contains(cursor)
                                =>Some((&mut self.todo_first,self.todos.items.len().saturating_sub(3))),
                            3 if clipboard_body
                                =>Some((&mut self.clip_first,self.clipboard.lock().items.len().saturating_sub(crate::pages::CLIP_ROWS))),
                            3 if !clipboard_tab && Rect::from_min_max(Pos2::new(36.0,28.0),Pos2::new(383.0,128.0)).contains(cursor)
                                =>Some((&mut self.shelf_first,self.shelf.items.len().saturating_sub(5))),
                            _=>None,
                        };
                        let content_scrolls=list.as_ref().is_some_and(|(_,max)|*max>0);
                        let scrolled=list.is_some_and(|(first,max)|{
                            let target=if next {(*first+1).min(max)}else{first.saturating_sub(1)};
                            let changed=target!=*first;*first=target;changed
                        });
                        // 内容溢出时滚动列表并停在边界；未溢出时滚轮翻页。
                        if !scrolled && !content_scrolls && !self.todo_choosing && self.t-self.wheel_page_at>=0.08 {
                            self.navigate_page(next);
                            self.wheel_page_at=self.t;
                        }
                        ctx.input_mut(|i|{i.raw_scroll_delta=Vec2::ZERO;i.smooth_scroll_delta=Vec2::ZERO;});
                    }
                }
            }
        } else {self.wheel_delta=0.0;}
'@
$wheel_handler_new = @'
        // 滚轮切页惯性只用窗口坐标判断位移，避免从矮页切到高页时 content_origin 变化被误判为移动。
        // 仅由滚轮触发的 navigate_page 启动锁定；点击/键盘 go()、编辑、阅读邮件、音量条展开都会清掉。
        if self.wheel_page_lock_pos.is_some() {
            let moved=env.cursor.map_or(true,|c|self.wheel_page_lock_pos.is_some_and(|p|c.distance(p)>WHEEL_PAGE_LOCK_MOVE));
            if self.t>=self.wheel_page_lock_until || moved || !self.open || !page_hover
                || self.is_editing() || self.todo_choosing || self.mail.open_uid.is_some() || self.music_volume_open
            {
                self.wheel_page_lock_until=-1.0;
                self.wheel_page_lock_pos=None;
            } else {
                ctx.input_mut(|i|i.smooth_scroll_delta=Vec2::ZERO);
            }
        }
        if (!self.is_editing() || self.todo_choosing) && page_hover && self.open && self.reveal > 0.95 {
            let (scroll_y, scroll_x, left, right, esc, shift) = ctx.input(|i| (i.raw_scroll_delta.y, i.raw_scroll_delta.x, i.key_pressed(egui::Key::ArrowLeft), i.key_pressed(egui::Key::ArrowRight), i.key_pressed(egui::Key::Escape), i.modifiers.shift));
            if esc { self.hover_lock = true; }
            if (left || right) && !self.todo_choosing {
                self.wheel_delta=0.0;
                self.navigate_page(right);
            } else {
                let cursor=env.cursor.unwrap()-self.content_origin(win).to_vec2();
                let mail_reading=inside && self.page==5 && self.mail.open_uid.is_some();
                // egui 0.31 在按下 Shift 时把垂直滚轮写入 raw_scroll_delta.x，并把 y 清零。
                let scroll=if shift {scroll_x+scroll_y}else{scroll_y};
                let force_page=!self.todo_choosing && !mail_reading && scroll!=0.0 && (shift || self.wheel_page_lock_pos.is_some());
                if force_page {
                    if self.t-self.wheel_at>0.18 || self.wheel_delta*scroll<0.0 {self.wheel_delta=0.0;}
                    self.wheel_at=self.t;
                    self.wheel_delta+=scroll;
                    if self.wheel_delta.abs()>=8.0 {
                        let next=self.wheel_delta<0.0;
                        self.wheel_delta=0.0;
                        if self.t-self.wheel_page_at>=0.08 {
                            let from=self.page;
                            self.navigate_page(next);
                            self.wheel_page_at=self.t;
                            if self.page!=from {
                                self.wheel_page_lock_until=self.t+WHEEL_PAGE_LOCK;
                                self.wheel_page_lock_pos=env.cursor;
                            }
                        }
                    }
                    ctx.input_mut(|i|{
                        i.raw_scroll_delta=Vec2::ZERO;
                        i.smooth_scroll_delta=Vec2::ZERO;
                        i.events.retain(|event|!matches!(event,egui::Event::MouseWheel{..}));
                    });
                } else if scroll_y!=0.0 {
                    let mail_list=self.page==5 && !self.mail.accounts.is_empty() && self.mail.open_uid.is_none() && self.mail_list_bounds().contains(cursor);
                    let music_volume=self.page==0 && (Rect::from_min_max(Pos2::new(354.0,106.0),Pos2::new(380.0,130.0)).contains(cursor)
                        || self.music_volume_open && crate::pages::MUSIC_VOLUME_RECT.contains(cursor));
                    if mail_reading || mail_list || music_volume {self.wheel_delta=0.0;}
                    else {
                        // 累积高精度滚轮的小幅输入；停顿或反向时丢弃上一段余量。
                        if self.t-self.wheel_at>0.18 || self.wheel_delta*scroll_y<0.0 {self.wheel_delta=0.0;}
                        self.wheel_at=self.t;
                        self.wheel_delta+=scroll_y;
                        if self.wheel_delta.abs()>=8.0 {
                            let next=self.wheel_delta<0.0;
                            self.wheel_delta=0.0;
                            let calendar_max=if self.page==CALENDAR_PAGE {self.calendar_scroll_max(env)}else{0};
                            let calendar_body=self.page==CALENDAR_PAGE && Rect::from_min_max(Pos2::new(163.0,52.0),Pos2::new(378.0,208.0)).contains(cursor);
                            let clipboard_tab=self.page==3 && self.shelf_tab==1;
                            let clipboard_body=clipboard_tab && Rect::from_min_max(Pos2::new(42.0,31.0),Pos2::new(377.0,124.0)).contains(cursor);
                            let list=match self.page {
                                CALENDAR_PAGE if calendar_body=>Some((&mut self.calendar.view.first,calendar_max)),
                                4 if Rect::from_min_max(Pos2::new(196.0,31.0),Pos2::new(377.0,124.0)).contains(cursor)
                                    =>Some((&mut self.todo_first,self.todos.items.len().saturating_sub(3))),
                                3 if clipboard_body
                                    =>Some((&mut self.clip_first,self.clipboard.lock().items.len().saturating_sub(crate::pages::CLIP_ROWS))),
                                3 if !clipboard_tab && Rect::from_min_max(Pos2::new(36.0,28.0),Pos2::new(383.0,128.0)).contains(cursor)
                                    =>Some((&mut self.shelf_first,self.shelf.items.len().saturating_sub(5))),
                                _=>None,
                            };
                            let content_scrolls=list.as_ref().is_some_and(|(_,max)|*max>0);
                            let scrolled=list.is_some_and(|(first,max)|{
                                let target=if next {(*first+1).min(max)}else{first.saturating_sub(1)};
                                let changed=target!=*first;*first=target;changed
                            });
                            // 内容溢出时滚动列表并停在边界；未溢出时滚轮翻页。
                            if !scrolled && !content_scrolls && !self.todo_choosing && self.t-self.wheel_page_at>=0.08 {
                                let from=self.page;
                                self.navigate_page(next);
                                self.wheel_page_at=self.t;
                                if self.page!=from {
                                    self.wheel_page_lock_until=self.t+WHEEL_PAGE_LOCK;
                                    self.wheel_page_lock_pos=env.cursor;
                                }
                            }
                            ctx.input_mut(|i|{i.raw_scroll_delta=Vec2::ZERO;i.smooth_scroll_delta=Vec2::ZERO;i.events.retain(|event|!matches!(event,egui::Event::MouseWheel{..}));});
                        }
                    }
                }
            }
        } else {self.wheel_delta=0.0;}
'@
Replace-UniqueSnippet `
    -Path $app `
    -Old $wheel_handler_old `
    -New $wheel_handler_new `
    -Label '滚轮切页惯性与 Shift+滚轮逻辑'

$test_frame_old = @'
    fn frame(&mut self, events: Vec<egui::Event>) {
        self.t += 1.0 / 60.0;
        let mut raw = egui::RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, Vec2::new(crate::app::CANVAS_W, WIN_H))),
            time: Some(self.t),
            events,
            hovered_files:self.hovered_files.clone(),
            dropped_files:std::mem::take(&mut self.dropped_files),
            focused: true,
            ..Default::default()
        };
'@
$test_frame_new = @'
    fn frame(&mut self, events: Vec<egui::Event>) {
        self.frame_with(events, Default::default());
    }
    fn frame_with(&mut self, events: Vec<egui::Event>, modifiers: egui::Modifiers) {
        self.t += 1.0 / 60.0;
        let mut raw = egui::RawInput {
            screen_rect: Some(Rect::from_min_size(Pos2::ZERO, Vec2::new(crate::app::CANVAS_W, WIN_H))),
            time: Some(self.t),
            events,
            hovered_files:self.hovered_files.clone(),
            dropped_files:std::mem::take(&mut self.dropped_files),
            focused: true,
            modifiers,
            ..Default::default()
        };
'@
Replace-UniqueSnippet `
    -Path $tests `
    -Old $test_frame_old `
    -New $test_frame_new `
    -Label 'ui_tests frame_with 修饰键入口'

$test_wheel_helper_old = @'
    fn wheel(&mut self,delta:f32) {
        self.frame(vec![egui::Event::MouseWheel{unit:egui::MouseWheelUnit::Point,delta:Vec2::new(0.0,delta),modifiers:Default::default()}]);
    }
    fn picker_frame(&mut self,events:Vec<egui::Event>){
'@
$test_wheel_helper_new = @'
    fn wheel(&mut self,delta:f32) {
        self.frame(vec![egui::Event::MouseWheel{unit:egui::MouseWheelUnit::Point,delta:Vec2::new(0.0,delta),modifiers:Default::default()}]);
    }
    fn wheel_shift(&mut self,delta:f32) {
        // egui 0.31 会按 Event 与 RawInput 两处的 Shift 把垂直滚轮写进 raw_scroll_delta.x。
        self.frame_with(vec![egui::Event::MouseWheel{unit:egui::MouseWheelUnit::Point,delta:Vec2::new(0.0,delta),modifiers:egui::Modifiers::SHIFT}],egui::Modifiers::SHIFT);
    }
    fn picker_frame(&mut self,events:Vec<egui::Event>){
'@
Replace-UniqueSnippet `
    -Path $tests `
    -Old $test_wheel_helper_old `
    -New $test_wheel_helper_new `
    -Label 'ui_tests wheel_shift 辅助函数'

$test_wheel_cases_old = @'
    h.click(H::local(350.0,48.0));assert!(h.app.mail.open_uid.is_none());
    h.hover(H::local(210.0,18.0),0.5);h.wheel(-120.0);
    assert_eq!(h.app.page(),6,"返回列表后顶栏滚轮应恢复翻页");
}

#[test]
fn reader_actions_remain_bound_to_the_opened_mailbox() {
'@
$test_wheel_cases_new = @'
    h.click(H::local(350.0,48.0));assert!(h.app.mail.open_uid.is_none());
    h.hover(H::local(210.0,18.0),0.5);h.wheel(-120.0);
    assert_eq!(h.app.page(),6,"返回列表后顶栏滚轮应恢复翻页");
}

fn overflowing_clipboard(h:&mut H){
    h.app.shelf_tab=1;
    h.app.clip_first=0;
    h.app.clipboard.lock().items.clear();
    for i in 0..(crate::pages::CLIP_ROWS+2){h.app.clipboard.lock().push(&format!("clip {i}"),"09:00");}
}
fn overflowing_todos(h:&mut H){
    h.app.todo_first=0;
    h.app.todos.items=(0..6).map(|i|crate::model::TodoItem{text:format!("任务 {i}"),..Default::default()}).collect();
}
fn overflowing_mailbox(h:&mut H){
    h.app.mail.accounts=vec![crate::mail::Account{custom:None,email:"test@qq.com".into(),provider:crate::mail::Provider::Qq,enabled:true}];
    h.app.mail.recent=(1..=8).map(|uid|crate::mail::Item{received_unix:None,account:"test@qq.com".into(),from:format!("来源 {uid}"),subject:format!("邮件 {uid}"),time:"11-03 09:41".into(),code:None,html:String::new().into(),summary:String::new().into(),links:vec![],meeting:None,uid}).collect();
}

#[test]
fn wheel_page_lock_crosses_overflowing_clipboard_todo_and_mail_and_allows_reverse(){
    let _g=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());let mut h=H::new();
    overflowing_clipboard(&mut h);overflowing_todos(&mut h);overflowing_mailbox(&mut h);
    let stay=H::local(300.0,60.0);
    h.app.show_page(2);h.hover(stay,0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,3,"应从健康页滚进剪贴板");assert_eq!(h.app.clip_first,0);
    h.hover(stay,0.12);h.wheel(-40.0);assert_eq!(h.app.page,4,"0.6s 内不动鼠标应穿过溢出的剪贴板");assert_eq!(h.app.clip_first,0,"惯性切页不能带动剪贴板列表");
    h.hover(stay,0.12);h.wheel(-40.0);assert_eq!(h.app.page,5,"0.6s 内应继续穿过溢出的待办");assert_eq!(h.app.todo_first,0);
    h.hover(stay,0.12);h.wheel(-40.0);assert_eq!(h.app.page,6,"0.6s 内应穿过邮箱列表");
    h.hover(stay,0.12);h.wheel(40.0);assert_eq!(h.app.page,5,"反向惯性应从额度页回到邮箱");
    h.hover(stay,0.12);h.wheel(40.0);assert_eq!(h.app.page,4,"反向惯性应能从邮箱列表直接回滚");
    h.hover(stay,0.12);h.wheel(40.0);assert_eq!(h.app.page,3);assert_eq!(h.app.todo_first,0);
    h.hover(stay,0.12);h.wheel(40.0);assert_eq!(h.app.page,2);assert_eq!(h.app.clip_first,0,"反向穿过剪贴板也不能滚动列表");
}

#[test]
fn wheel_page_lock_expires_after_pause_or_pointer_move_and_scrolls_lists(){
    let _g=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());let mut h=H::new();
    overflowing_clipboard(&mut h);overflowing_todos(&mut h);overflowing_mailbox(&mut h);
    h.app.show_page(2);h.hover(H::local(300.0,60.0),0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,3);assert_eq!(h.app.clip_first,0);
    h.hover(H::local(300.0,60.0),0.7);
    h.wheel(-40.0);assert_eq!(h.app.page,3,"停顿超过 0.6s 后应恢复内部滚动");assert_eq!(h.app.clip_first,1);
    overflowing_clipboard(&mut h);
    h.app.show_page(2);h.hover(H::local(300.0,60.0),0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,3);
    h.hover(H::local(300.0,72.0),0.05);
    h.wheel(-40.0);assert_eq!(h.app.page,3,"移动超过 10px 后应解锁并滚动列表");assert_eq!(h.app.clip_first,1);
    h.app.show_page(3);h.app.todo_first=0;h.hover(H::local(300.0,60.0),0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,4);assert_eq!(h.app.todo_first,0);
    h.hover(H::local(300.0,60.0),0.7);
    h.wheel(-40.0);assert_eq!(h.app.page,4,"待办在锁定过期后应内部滚动");assert_eq!(h.app.todo_first,1);
    // (100,90) 在待办列表外、邮箱列表内，保证先切进邮箱再于原位等待过期。
    h.app.show_page(4);h.hover(H::local(100.0,90.0),0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,5);
    h.hover(H::local(100.0,90.0),0.7);
    h.wheel(-40.0);assert_eq!(h.app.page,5,"邮箱列表在锁定过期后应留下内部滚动，不切页");
}

#[test]
fn shift_wheel_turns_pages_inside_overflowing_lists_including_mail(){
    let _g=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());let mut h=H::new();
    overflowing_clipboard(&mut h);overflowing_todos(&mut h);overflowing_mailbox(&mut h);
    h.app.show_page(3);h.hover(H::local(300.0,60.0),0.5);
    h.wheel_shift(-40.0);assert_eq!(h.app.page,4);assert_eq!(h.app.clip_first,0,"Shift+滚轮切页不能滚动剪贴板");
    h.app.show_page(4);h.hover(H::local(300.0,60.0),0.5);
    h.wheel_shift(-40.0);assert_eq!(h.app.page,5);assert_eq!(h.app.todo_first,0,"Shift+滚轮切页不能滚动待办");
    h.app.show_page(5);h.hover(H::local(200.0,90.0),0.5);
    h.wheel_shift(-40.0);assert_eq!(h.app.page,6,"Shift+滚轮应能从溢出的邮箱列表直接切页");
    h.app.show_page(5);h.hover(H::local(200.0,90.0),0.5);
    h.wheel_shift(40.0);assert_eq!(h.app.page,4,"Shift+滚轮反向也应切页");
}

#[test]
fn mail_reading_ignores_shift_wheel_and_page_lock(){
    let _g=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());let mut h=H::new();
    overflowing_mailbox(&mut h);
    h.app.mail.recent[0].summary="正文内容。".repeat(200).into();
    h.app.show_page(4);h.hover(H::local(100.0,90.0),0.5);
    h.wheel(-40.0);assert_eq!(h.app.page,5,"应先滚进邮箱列表并启动惯性");
    h.app.mail.open_uid=Some(("test@qq.com".into(),1));
    h.hover(H::local(100.0,90.0),0.05);
    h.wheel(-120.0);h.wheel_shift(-120.0);h.wheel_shift(120.0);
    assert_eq!(h.app.page(),5,"阅读邮件正文时即使刚切页或按住 Shift 也不能翻页");
    assert_eq!(h.app.mail.open_uid,Some(("test@qq.com".into(),1)));
    h.app.show_page(5);h.app.mail.open_uid=Some(("test@qq.com".into(),1));
    for (x,y) in [(210.0,18.0),(200.0,90.0),(270.0,214.0)]{
        h.hover(H::local(x,y),0.5);h.wheel_shift(-120.0);
        assert_eq!(h.app.page(),5,"阅读邮件时在 ({x},{y}) 按住 Shift 也不能翻页");
        assert_eq!(h.app.mail.open_uid,Some(("test@qq.com".into(),1)));
    }
}

#[test]
fn reader_actions_remain_bound_to_the_opened_mailbox() {
'@
Replace-UniqueSnippet `
    -Path $tests `
    -Old $test_wheel_cases_old `
    -New $test_wheel_cases_new `
    -Label '滚轮惯性与 Shift+滚轮测试'

Write-Host ("已将悬停延迟改为 HOVER_INTENT={0}s、MINIMAL_HOVER_INTENT={1}s，更新源改为 {2}，并打上 0.60s 滚轮切页惯性与 Shift+滚轮补丁。" -f $HoverIntent, $MinimalHoverIntent, $TargetRepo)
