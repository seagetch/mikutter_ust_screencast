# -*- coding: utf-8 -*-
# デスクトップまるみえ
# mikutterとならどこでも自分のデスクトップを公開しても安心！プラグイン

require "#{File.dirname(__FILE__)}/avconv"

# デスクトップの有効なサイズを得る
def get_workarea()
  atom = Gdk::Atom.intern("_NET_CURRENT_DESKTOP",true)
  desktop = Gdk::Property::get(Gdk::Window.default_root_window, atom, Gdk::Atom.intern('CARDINAL', true), false)[1][0]

  atom = Gdk::Atom.intern("_NET_WORKAREA",true) 
  return Gdk::Property::get(Gdk::Window.default_root_window, atom, Gdk::Atom.intern('CARDINAL', true), false)[1][desktop * 4, 4]
end

def get_root_window_size()
  screen = Gdk::Screen.default
  return [screen.width, screen.height]
end

#ストリーミングの送信サイズを指定する
def calc_streaming_bound(w, h, w_threshold, h_threshold)
  w_threshold = w unless w_threshold
  h_threshold = h unless h_threshold
  return [0, 0] if w == 0 || h == 0
  w1 = w_threshold
  h1 = (h * w1 / w).to_i
  h2 = h_threshold
  w2 = (w * h2 / h).to_i
  notice "calc_streaming_bound:#{w1},#{h1} / #{w2},#{h2}"
  if w1 < w2 && w1 > 0 then
    return [w1, h1]
  else
    return [w2, h2]
  end
end

# MikutterWindowを拡張する
class ::Gtk::MikutterWindow
  def add_toplevel_widget(widget, start_side = false)
    if start_side then
      @container.pack_start(widget, false)
      @container.reorder_child(widget, 0)
    else
      last = @container.children.length
      @container.pack_start(widget, false)
      @container.reorder_child(widget, last - 1)
    end
  end
  
  def remove_toplevel_widget(widget)
    @container.remove(widget)
  end
end

module LibavViewer
  class SDLViewer
    def initialize(path, hash = nil)
      @path = path
      @hash = hash
    end
    
    # Update SDL Surface
    def run(context)
      #Initialize
      notice "Run SDLViewer"
      env = {}
      ENV.each {|k,v| env[k] = v }
      env["SDL_WINDOWID"] = @hash.to_s
      exec_path="avplay"
      args = ["-vf",
              "scale=#{context[:width]}:#{context[:height]}",
              "-an",
              @path]
      notice "Run #{exec_path} #{args.join(" ")}"
      @pid = spawn(env, exec_path, *args, :err => "/dev/null", :out => "/dev/null")
    end
    
    def wait
      if @pid then
        Process.waitpid(@pid)
      end
    end
    
    # stop running thread
    def stop
      if @pid then
        Process.kill(:SIGTERM, @pid)
      end
    end
  end
end

# Plugin本体
Plugin.create(:ust_screencast) do
  WORK_AREA = get_workarea
  
  screen_w, screen_h = get_root_window_size
  
  if UserConfig[:ust_screencast_screen] == nil then
    screen = Gdk::Screen.default
    display = screen.display
    UserConfig[:ust_screencast_screen] = "#{display.name}.#{screen.number}"
  end
  if UserConfig[:ust_screencast_capture_w] == nil then
    UserConfig[:ust_screencast_capture_w] = screen_w
  end
  if UserConfig[:ust_screencast_capture_h] == nil then
    UserConfig[:ust_screencast_capture_h] = screen_h
  end
  if UserConfig[:ust_screencast_capture_x] == nil then
    UserConfig[:ust_screencast_capture_x] = 0
  end
  if UserConfig[:ust_screencast_capture_y] == nil then
    UserConfig[:ust_screencast_capture_y] = 0
  end

  # 設定画面
  settings "デスクトップまるみえ" do
    settings "Ustream Streaming" do
      input("Server URL", :ust_screencast_server)
      input("Secret Key", :ust_screencast_secret)
    end
    settings "ツイート" do
      input("ショートカットURL(例： http://ustre.am/****)", :ust_screencast_shortcut)
    end
    settings "アップロード動画" do
      input("対象ディスプレイ", :ust_screencast_screen)
      adjustment("キャプチャ開始X座標(px)", :ust_screencast_capture_x, 0, screen_w)
      adjustment("キャプチャ開始Y座標(px)", :ust_screencast_capture_y, 0, screen_h)
      adjustment("キャプチャ画面横幅(px)" , :ust_screencast_capture_w, 0, screen_w)
      adjustment("キャプチャ画面高さ(px)" , :ust_screencast_capture_h, 0, screen_h)
      
      adjustment("アップロード動画の高さ", :ust_screencast_upload_height, 
                 30, WORK_AREA[3])
      input("アイコン画像ファイル(pngとか)", :ust_screencast_overlay_icon)
      select("音源", :ust_screencast_audio_source) do
        lines = IO.popen([{"LANG"=>"C"}, "pactl","list","sources"]) {|r| r.read }
        lines.split("\n").grep(/Name/).map {|i| i.gsub(/.*Name: /,"") }.
          each {|l|
            if l && l != "" then
              option l, l
            end
          }
      end
    end
    settings "プレビュー" do
      adjustment("動画サイズ（高さ指定）", :ust_screencast_view_height, 
                 30, WORK_AREA[3])
    end
  end

  converter     = nil
  viewer        = nil
  viewer_widget = nil
  window        = nil
  toggle_lock   = Mutex.new
  postboxes = []
  
  # 起動時処理(for 0.2)
  on_window_created do |i_window|
    # メインウインドウを取得
    window_tmp = Plugin.filtering(:gui_get_gtk_widget,i_window)

    if (window_tmp == nil) || (window_tmp[0] == nil) then
      next
    end

    window = window_tmp[0]
  end
  
  on_postbox_created do |postbox|
    postboxes << postbox
  end
  
  # converter status change event handler
  status_changed_handler = Proc.new { |o, new_status|
    begin
      notice "status changed -> #{new_status}"
      case new_status
      when Avconv::Converter::STAT_CONVERTING
        ust_server = UserConfig[:ust_screencast_server]
        ust_key    = UserConfig[:ust_screencast_secret]
        ust_uri = "#{ust_server}/#{ust_key}"
        capture_w  = UserConfig[:ust_screencast_capture_w]
        capture_h  = UserConfig[:ust_screencast_capture_h]
      
        #アップロードを開始したらビューアを登録する
        notice "Start converting"

        viewer_h = UserConfig[:ust_screencast_view_height]
        viewer_size = calc_streaming_bound(capture_w, capture_h, nil, viewer_h)

        #表示領域を確保
        if window then
          notice "Add new drawing area"
          viewer_widget = ::Gtk::DrawingArea.new
          viewer_widget.set_size_request(viewer_size[0], viewer_size[1])
          viewer_widget.show

          viewer_widget.events |= Gdk::Event::BUTTON_PRESS_MASK

          viewer_widget.ssc("button-press-event") do |event|
            notice "[ust_screencast]viewer_widget.button_press_event"
            ust_shortcut = UserConfig[:ust_screencast_shortcut]
            next unless ust_shortcut
            notice "[ust_screencast]find postboxes and insert (#{ust_shortcut})"
            postboxes.each {|pb|
              if pb.editable? then
                notice "[ust_screencast]insert shortcut(#{ust_shortcut})"
                gtk_pb = Plugin.filtering(:gui_get_gtk_widget, pb)[0]
                signature = "(#{ust_shortcut})"
                orig_text = gtk_pb.post.buffer.text
                if orig_text.gsub!(signature,"").nil? then
                  orig_text += signature
                end
                gtk_pb.post.buffer.text = orig_text
              end
            }
          end
 
          window.add_toplevel_widget(viewer_widget)
        end
        
        notice "Creating new viewer"
        window_id = viewer_widget ? viewer_widget.window.xid : nil
        notice "window_id=#{window_id.to_s}"
        viewer = LibavViewer::SDLViewer.new(ust_uri, window_id)
        notice "Start running"
        viewer.run(:width => viewer_size[0], :height => viewer_size[1])

        #FIXME: ここでロック解除したいが、別スレッドなので解放できない。
#        toggle_lock.unlock
        
      when Avconv::Converter::STAT_FINISHING
      end
    rescue => e
      error "#{e.message}\n#{e.backtrace.join("\n")}"
      #FIXME: ここでロック解除したいが、別スレッドなので解放できない。
#      toggle_lock.unlock if toggle_lock.locked?
      raise e
    end
  }
  
  # Invoke screencaster process
  start_screencast = Proc.new {
    capture_x      = UserConfig[:ust_screencast_capture_x]
    capture_y      = UserConfig[:ust_screencast_capture_y]
    capture_w      = UserConfig[:ust_screencast_capture_w]
    capture_h      = UserConfig[:ust_screencast_capture_h]
    capture_screen = UserConfig[:ust_screencast_screen]
    h_threshold    = UserConfig[:ust_screencast_upload_height]

    overlay_icon = UserConfig[:ust_screencast_overlay_icon]
    overlay_icon = "#{File::dirname(__FILE__)}/mikutter.png" unless overlay_icon
    out_w, out_h = calc_streaming_bound(capture_w, capture_h, nil, h_threshold)
    out_w -= 1 if out_w%2 > 0

    ust_server = UserConfig[:ust_screencast_server]
    ust_key    = UserConfig[:ust_screencast_secret]
    ust_uri = "#{ust_server}/#{ust_key}"

    audio_monitor = UserConfig[:ust_screencast_audio_source]

    # Build up conversion information
    converter = Avconv::Converter.new

    # Input sources
    screen_stream = converter.x11grab(capture_screen, 
                                      capture_x, capture_y, 
                                      capture_w, capture_h) do
      r(10)
    end
    icon_stream = converter.input(overlay_icon) do
      format "image2"
      framerate(10)
    end
    pulse_stream = converter.input(audio_monitor) do
      format "pulse"
    end
    
    # Output sink
    converter.output(ust_uri) do
      format "flv"
      codec(video => "libx264", audio => "aac")
      strict "experimental"
      ar 44100
      vb "1000k"
      ab "128k"
      force
    end
    
    # Filtering
    converter.filter_complex do
      filter(screen_stream.video => "desktop") {
        scale out_w, out_h
        setpts "PTS-STARTPTS"
      }
      filter(icon_stream.video => "banner") {
        setpts "PTS-STARTPTS"
      }
      filter(["desktop","banner"] => nil) {
        overlay(0, "main_h-overlay_h")
      }
    end
    
    # Register Callbacks
    converter.register_handler(:status_changed, &status_changed_handler)

    toggle_lock.lock
    begin
      converter.run
    rescue => e
      toggle_lock.unlock
    end
  }
  
  # Shutdown screencaster process
  stop_screencast = Proc.new {
    if toggle_lock.locked? then
      toggle_lock.sleep(10)
    end

    toggle_lock.synchronize {
      #ビューアを停止する
      if viewer then
        viewer.stop
        viewer = nil
      end

      if viewer_widget then
        window.remove_toplevel_widget(viewer_widget)
        viewer_widget = nil
      end

      #コンバータを終了する
      converter.stop
      converter = nil
    }
  }

  # Register Mikutter command  
  command(:toggle_screencast,
          name: 'Ustへのデスクトップ配信の開始/停止を切り替える',
          condition: lambda{ |opt| true },
          visible: true,
          icon: "#{File.dirname(__FILE__)}/ust-off-icon.png",
          role: :window) do |event|
    if viewer_widget && toggle_lock.locked? then
      toggle_lock.unlock
    end

    if converter then
      stop_screencast.call()
    else
      start_screencast.call()
    end
  end

  #privateな人のツイートは表示しないように
  filter_update do |svc, msgs|
    if converter then
      msgs = msgs.select {|msg| !msg.user[:protected] }
    end
    [svc, msgs]
  end

end
