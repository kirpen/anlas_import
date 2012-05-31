# encoding: UTF-8
module AnlasImport

  BACKUP_DIR = "/home/webmaster/backups/imports/"

  # Сохранение данных (добавление новых, обновление сущестующих), полученных
  # при разборе xml-файла.
  class Worker

    MOG_EQ = {
      'g' => 'a',
      'v' => 'v',
      'h' => 'h',
      'a' => '',
      'e' => 'e',
      't' => 't',
      'z' => 'z',
      'i' => 'i'
    }

    def initialize(file, conn)

      @errors, @ins, @upd = [], [], []
      @file, @conn = file, conn

      @file_name = ::File.basename(@file)

      unless @file && ::FileTest.exists?(@file)
        @errors << "Файл не найден: #{@file}"
      else
        @errors << "Не могу соединиться с базой данных!" unless @conn
      end # unless

    end # new

    def parse

      work_with_file if @errors.empty?
      self

    end # parse_file

    def errors
      @errors
    end # report

    def updated
      @upd
    end # updated

    def inserted
      @ins
    end # insert

    private

    def init_saver(catalog)

      # Блок сохраниения данных в базу
      @saver = lambda { |artikul, artikulprod, name, purchasing_price, available, gtd_number, storehouse|

        name        = clear_name(name).strip.escape
        artikul     = artikul.strip.escape
        artikulprod = artikulprod.strip.escape

        # Проверка товара на наличие букв "яя" вначле названия (такие товары не выгружаем)
        unless skip_by_name(name)

          orig_artikul = artikul
          finded = target_exists(orig_artikul)

          #unless finded
            #postfix = artikul[/[gvhaetzi]$/]
            #if postfix
              #artikul = orig_artikul.sub(/[gvhaetzi]$/, '')
              #artikul = MOG_EQ[postfix] + artikul
              #finded  = target_exists(artikul)
            #end # if
          #end # unless

          if finded

            if update(artikul, name, purchasing_price, available)
              @upd << artikul
            end

          else

            if insert(artikul, artikulprod, name, purchasing_price, available, gtd_number, storehouse, catalog)
              @ins << artikul
            end

          end

        end # unless

      } # saver

    end # init_saver

    def work_with_file

      unless (catalog = catalog_for_import( prefix_file ))
       @errors << "Каталог выгрузки не найден! Файл: #{@file}"
      else

        init_saver(catalog)

        pt = ::AnlasImport::XmlParser.new(@saver)

        parser = ::Nokogiri::XML::SAX::Parser.new(pt)
        parser.parse_file(@file)

        unless (errors = pt.errors).empty?
          @errors << errors
        end

        begin
          ::FileUtils.mv(@file, AnlasImport::BACKUP_DIR)
        rescue SystemCallError
          puts "Не могу переместить файл `#{@file_name}` в `#{AnlasImport::BACKUP_DIR}`"
          ::FileUtils.rm_rf(@file)
        end

      end # unless

    end # work_with_file

    def catalog_for_import(prefix)

      catalog_import = @conn.collection("catalogs").find_one({
        "import_prefix" => (prefix.blank? ? "_" : prefix)
      })

      catalog_import ? catalog_import : false

    end # catalog_for_import

    def target_exists(marking_of_goods)

      item = @conn.collection("items").find_one({
        "marking_of_goods" => marking_of_goods
      })

      item ? item : false

    end # target_exists

    def insert(artikul, artikulprod, name, purchasing_price, available, gtd_number, storehouse, catalog)

      doc = {

        "name_1c"         => name,
        "name"            => name,
        "meta_title"      => name,
        "unmanaged"       => true,

        "purchasing_price"=> purchasing_price.to_i,

        "storehouse"      => storehouse,
        "gtd_number"      => gtd_number,

        "marking_of_goods" => artikul,
        "available"       => available.to_i,
        "marking_of_goods_manufacturer" => artikulprod,

        "imported_at"     => ::Time.now.utc,
        "created_at"      => ::Time.now.utc,

        "catalog_id"      => catalog["_id"],
        "catalog_lft"     => catalog["lft"],
        "catalog_rgt"     => catalog["rgt"]
      }

      opts = { :safe => true }

      begin

        @conn.collection("admin").update(
          {:name => "Item_counter"}, {"$inc" => {:count => 1}}, {:upsert => true}
        )

        counter = @conn.collection("admin").find_one(:name => "Item_counter")
        doc["uri"] = (counter ? counter["count"] : 0)

        @conn.collection("items").insert(doc, opts)

        return true

      rescue => e
        @errors << "[INSERT: #{artikul}] #{e}"
        return false
      end # begin

    end # insert

    def update(artikul, name, purchasing_price, available)

      selector = { "marking_of_goods" => artikul }

      doc = {
        "name_1c"           => name,
        "purchasing_price"  => purchasing_price.to_i,
        "available"         => available.to_i,
        "imported_at"       => ::Time.now.utc
      }

      opts = { :safe => true }

      begin

        @conn.collection("items").update(selector, { "$set" => doc }, opts)
        return true

      rescue => e
        @errors << "[UPDATE: #{artikul}] #{e}"
        return false
      end # begin

    end # update

    def skip_by_name(name)
      (name =~ /^я{2,}/u) === 0
    end # skip_by_name

    def clear_name(name)
      name.sub(/\s{0,}\+\s{0,}подарок\!{0,}\z/i, "")
    end # clear_name

    def prefix_file
      @file_name.scan(/^([a-z]+)_/).flatten.first || ""
    end # prefix_file

  end # Worker

end # AnlasImport
