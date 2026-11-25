# 악보 플레이어 (MusicPlayer)

악보를 촬영하거나 PDF·사진으로 가져와 디지털 악보로 바꾸고, 편집하고, PDF로 내보내고, 피아노 소리로 재생하고,
마이크로 내 피아노 연주를 들으며 맞게 치는지 알려 주는 iOS 앱입니다.

## 기능

| 기능 | 설명 |
|---|---|
| 악보 인식 | 카메라 문서 스캔(VisionKit), 사진 보관함, PDF·이미지 파일 → 사진의 기울기·원근을 펴고 흑백·대비 보정 → Claude 비전 API(`claude-opus-5-5`)가 큰보표(오른손/왼손) 악보 데이터로 변환. 'AI 2차 검토'를 켜면 AI가 첫 결과를 원본과 마디마다 다시 대조해 고침(박자 합이 안 맞는 마디를 단서로 줌). 편집 중 'AI로 이 마디 다시 읽기'로 틀린 마디만 원본에서 다시 인식 |
| 정리·편집 | 음표를 눌러 선택 → 음높이(반음/옥타브, 화면 건반으로 직접 지정, 화음 넣기/빼기), 길이·점, 쉼표 전환, 오른손↔왼손 옮기기, 음표·마디 추가/삭제. 표식(스타카토·악센트·테누토·페르마타·붙임줄), 셈여림(pp~ff), 손가락 번호, 도돌이표 수정. ‹ › 로 다음 음표 이동, 되돌리기/다시 하기, 원본 악보 사진을 위에 띄워 비교하며 수정. 제목·빠르기·박자·조표 수정, 마디 박자 합 검사 |
| 페이지(책) 관리 | 한 악보를 여러 페이지의 책으로 관리: 카메라·사진·PDF로 페이지 추가, 다른 악보를 페이지로 넣기, 빈 페이지, 끌어서 순서 바꾸기, 페이지 빼기·이름 바꾸기·앞 페이지와 합치기, 편집 중 '여기서 새 페이지'로 나누기. 가져오기 화면에서도 인식 전에 페이지 순서를 바꿀 수 있음. PDF도 페이지마다 새 쪽에서 시작 |
| PDF 내보내기 | A4 PDF로 그려 공유 시트로 저장·전송 |
| 피아노 재생 | 내장 신시사이저로 재생(도돌이표 반복, 붙임줄, 스타카토·악센트·페르마타·셈여림 반영), 빠르기 조절, 양손/오른손/왼손 선택, 재생 중인 음표 표시와 자동 스크롤 |
| 연습 모드 | 칠 음을 악보와 화면 건반에 파란색으로 표시 → 마이크로 듣고 맞으면 다음 음으로 넘어감. 틀린 음은 "반음 높아요 → 바로 왼쪽 건반", "한 옥타브 높게 쳤어요"처럼 고치는 방법을 알려 주고, 친 음은 결과대로(초록=한 번에, 주황=틀린 뒤 맞힘, 회색=건너뜀) 악보에 남김. 연속 정답, 실시간 정확도, 진동 피드백. 끝나면 결과 리포트(별점, 마디별 결과, 자주 틀린 음, 박자 안정도, 연습 팁)와 '틀린 마디만 다시 연습' 제공 |

API 키 없이도 예제 악보(작은 별)로 재생·편집·PDF·연습 기능을 모두 써 볼 수 있습니다.

## 빌드 방법 (Mac)

1. Xcode 16 이상이 필요합니다. 최소 지원 버전은 iOS 17입니다.
2. 저장소 받기
   ```bash
   git clone https://github.com/mrnoh99/MusicPlayer.git
   ```
3. `MusicPlayer/MusicPlayer.xcodeproj`를 더블클릭해서 엽니다.
4. 시뮬레이터를 골라 ⌘R을 누르면 바로 실행됩니다.
5. 실제 iPhone에서 실행하려면 프로젝트 → TARGETS `MusicPlayer` → **Signing & Capabilities**에서 **Team**에 본인 Apple ID를 고르세요.
   번들 ID가 겹치면 `com.mrnoh99.MusicPlayer`를 다른 값으로 바꾸면 됩니다.

> 카메라 스캔과 마이크 연습은 실제 기기에서만 제대로 동작합니다. 시뮬레이터에서는 파일·사진 가져오기를 사용하세요.

## iCloud 동기화 · 저장

악보, 원본 사진, 연습 기록(진도·이어서 할 위치), 내보낸 PDF를 **iCloud Drive의 '악보 플레이어' 폴더**에 저장합니다.
같은 Apple ID로 로그인한 iPhone·iPad에서 앱을 열면 자동으로 맞춰지고, 파일 앱 → iCloud Drive → 악보 플레이어에서도 볼 수 있습니다.
API 키는 iCloud 키체인으로 함께 맞춰집니다. iCloud를 쓸 수 없으면 기기 안에 저장합니다(목록 화면 왼쪽 위 ☁︎ 아이콘으로 상태 확인).

처음 한 번 Xcode 설정이 필요합니다.
1. iCloud 기능은 **유료 Apple Developer Program**(연 $99) 팀에서만 서명할 수 있습니다. 무료 개인 팀으로 빌드하려면
   TARGETS `MusicPlayer` → Build Settings → `Code Signing Entitlements`(`Config/MusicPlayer.entitlements`) 값을 지우세요(그러면 기기 안에만 저장).
2. Signing & Capabilities 에서 Team 을 고르면 iCloud(iCloud Documents) 기능과 컨테이너 `iCloud.com.mrnoh99.MusicPlayer`가 자동 등록됩니다.
   번들 ID를 바꿨다면 컨테이너 이름도 `iCloud.<새 번들 ID>`로 바꾸고, `Config/Info.plist`, `Config/MusicPlayer.entitlements`, `Model/SyncFolder.swift`의 `containerID`를 같이 바꿉니다.
3. 각 기기의 설정 앱 → Apple ID → iCloud → iCloud Drive 가 켜져 있어야 합니다.

## 악보 인식 설정

앱 첫 화면 왼쪽 위 ⚙︎ → Anthropic API 키(`sk-ant-…`)를 입력합니다. 키는 기기 키체인에만 저장됩니다.
인식 한 번에 보통 수십 초~몇 분이 걸리고, API 사용량만큼 요금이 부과됩니다.

## 구조

```
MusicPlayer/
├─ MusicPlayer.xcodeproj
└─ MusicPlayer/
   ├─ MusicPlayerApp.swift
   ├─ Model/        Score(마디·음표·박자·조표·페이지), 저장소, iCloud 폴더(SyncFolder)
   ├─ Rendering/    오선 배치(ScoreLayout), CoreGraphics 그리기(ScoreDrawer), 화면 뷰
   ├─ Editor/       음표 편집 도구, 악보 정보
   ├─ Recognition/  Claude OMR, 카메라 스캐너, PDF→이미지, 키체인
   ├─ Export/       PDF 내보내기
   ├─ Audio/        피아노 신시사이저, 재생기
   ├─ Practice/     마이크 FFT 분석, 음 판정, 연습 세션, 화면 건반
   └─ Views/        목록·상세·설정 화면
```

## 한계

- 음 판정은 FFT 스펙트럼에서 기음과 배음을 찾는 방식이라 조용한 곳에서 가장 정확합니다. 시끄러우면 연습 화면 메뉴에서 민감도를 낮추세요.
- 셋잇단, 성부가 여러 개인 악보, 1·2번 괄호(volta)는 단순화해서 인식합니다. 인식 뒤 편집 화면에서 고칠 수 있습니다.
