module Stupidedi
  module Builder

    class BuilderDsl
      include Inspect
      include Tokenization

      # @private
      SEGMENT_ID = /^[A-Z][A-Z0-9]{1,2}$/

      # @return [StateMachine]
      attr_reader :machine

      # @return [Boolean]
      attr_writer :strict

      delegate :pretty_print, :to => :@machine

      def initialize(machine, strict = true)
        @machine = machine
        @strict  = strict
        @reader  = DslReader.new(Reader::Separators.empty,
                                 Reader::SegmentDict.empty)
      end

      def strict?
        @strict
      end

      # (see Navigation#successors)
      def successors
        @machine.successors
      end

      # (see Navigation#zipper)
      def zipper
        @machine.zipper
      end

      # @return [BuilderDsl]
      def segment!(name, position, *elements)
        segment_tok     = mksegment_tok(@reader.segment_dict, name, elements, position)
        machine, reader = @machine.insert(segment_tok, @reader)

        if @strict
          # Validate the new segment (recursively, including its children)
          machine.active.each{|m| critique(m.node.zipper) }

          # We want to detect when we've ended a syntax node (or more), like
          # starting a new interchange will end all previously "open" syntax
          # nodes. So we compare the state before adding `segment_tok` to the
          # corresponding state after we've added `segment_tok`.

          machine.prev.tap do |prev|
            prev.active.zip(machine.active) do |p, q|
              # If the new state `q` is a descendent of `p`, we know that `p`
              # and all of its ancestors are unterminated. However, if `q` is
              # not a descendent of `p`, but is a descendent of one of `p`s
              # descendents, then `p` and perhaps some of its ancestors were
              # terminated when the state transitioned to `q`.
              qancestors = Set.new

              # Operate on the syntax tree (instead of the state tree)
              q = q.node.zipper
              p = p.node.zipper

              while q.respond_to?(:parent)
                qancestors << q.parent
                q = q.parent
              end

              while p.respond_to?(:parent)
                break if qancestors.include?(p)

                critique(p)
                p = p.parent
              end
            end
          end
        end

        @machine = machine
        @reader  = reader

        self
      end

    private

      def method_missing(name, *args)
        if SEGMENT_ID =~ name.to_s
          segment!(name, Reader::Position.caller(2), *args)
        else
          super
        end
      end

      # The `zipper` argument should be a _completed_ syntax node, meaning all
      # children have already been added. This is invariably true for segments,
      # because the {StateMachine} does not accept smaller units of syntax.
      def critique(zipper, descriptor = "")
        if zipper.node.simple? or zipper.node.component?
          if zipper.node.invalid?
            raise "invalid #{descriptor}"
          elsif zipper.node.blank?
            if zipper.node.usage.required?
              raise "required #{descriptor} is blank"
            end
          elsif zipper.node.usage.forbidden?
            raise "forbidden #{descriptor} is present"
          elsif zipper.node.usage.allowed_values.exclude?(zipper.node.to_s)
            raise "value #{zipper.node.to_s} not allowed in #{descriptor}"
          elsif zipper.node.too_long?
            raise "value is too long in #{descriptor}"
          elsif zipper.node.too_short?
          # raise "value is too short in #{descriptor}"
          end

        elsif zipper.node.composite?
          if zipper.node.blank?
            if zipper.node.usage.required?
              raise "required #{descriptor} is blank"
            end
          elsif zipper.node.usage.forbidden?
            raise "forbidden #{descriptor} is present"
          else
            if zipper.node.present?
              zipper.children.each_with_index do |z, i|
                critique(z, "#{descriptor}-#{'%02d' % (i + 1)}")
              end

              d = zipper.node.definition
              d.syntax_notes.each do |s|
                raise "for #{descriptor}, #{s.reason(zipper)}" \
                  unless s.satisfied?(zipper)
              end
            end
          end

        elsif zipper.node.repeated?
          zipper.children.each{|z| critique(z) }

        elsif zipper.node.segment?
          descriptor = zipper.node.id

          if zipper.node.invalid?
            raise "invalid segment #{descriptor}"
          else
            zipper.children.each_with_index do |z, i|
              critique(z, "#{descriptor}-#{'%02d' % (i + 1)}")
            end

            d = zipper.node.definition
            d.syntax_notes.each do |s|
              raise "for #{descriptor}, #{s.reason(zipper)}" \
                unless s.satisfied?(zipper)
            end
          end

        elsif zipper.node.loop?
          name = zipper.node.definition.id
          occurences = Hash.new{|h,k| h[k] = 0 }

          zipper.children.each do |child|
            # Child is either a segment or loop
            if child.node.loop?
              occurences[child.node.definition] += 1
            else
              occurences[child.node.usage] += 1
            end
          end

          zipper.node.definition.children.each do |child|
            bound = child.repeat_count
            count = occurences.at(child)

            if count.zero? and child.required?
              if child.loop?
                raise "required loop #{child.id} is missing from #{name}"
              else
                raise "required segment #{child.id} is missing from #{name}"
              end
            elsif bound < count
              if child.loop?
                raise "loop #{child.id} occurs too many times in #{name}"
              else
                raise "segment #{child.id} occurs too many times in #{name}"
              end
            end
          end

        elsif zipper.node.table?
          name = zipper.node.definition.id
          occurences = Hash.new{|h,k| h[k] = 0 }

          zipper.children.each do |child|
            # Child is either a segment or loop
            if child.node.loop?
              occurences[child.node.definition] += 1
            else
              occurences[child.node.usage] += 1
            end
          end

          zipper.node.definition.children.each do |child|
            bound = child.repeat_count
            count = occurences.at(child)

            if count.zero? and child.required?
              if child.loop?
                raise "required loop #{child.id} is missing from #{name}"
              else
                raise "required segment #{child.id} is missing from #{name}"
              end
            elsif bound < count
              if child.loop?
                raise "loop #{child.id} occurs too many times in #{name}"
              else
                raise "segment #{child.id} occurs too many times in #{name}"
              end
            end
          end

        elsif zipper.node.transaction_set?
          # puts "transaction set: #{zipper.node.definition.id}"
          # @todo
        elsif zipper.node.functional_group?
          # puts "functional group: #{zipper.node.definition.id}"
          # @todo
        elsif zipper.node.interchange?
          # puts "interchange: #{zipper.node.definition.id}"
          # @todo
        elsif zipper.node.transmission?
          # puts "transmission: ???"
          # @todo
        end
      end

      # @endgroup
      #########################################################################
    end

    class << BuilderDsl
      # @group Constructors
      #########################################################################

      # @return [BuilderDsl]
      def build(config, strict = true)
        new(StateMachine.build(config), strict)
      end

      # @endgroup
      #########################################################################
    end

    # @private
    class DslReader

      # @return [Reader::Separators]
      attr_reader :separators

      # @return [Reader::SegmentDict]
      attr_reader :segment_dict

      def initialize(separators, segment_dict)
        @separators, @segment_dict = separators, segment_dict
      end

      # @return [DslReader]
      def copy(changes = {})
        @separators   = changes.fetch(:separators, @separators)
        @segment_dict = changes.fetch(:segment_dict, @segment_dict)
        self
      end
    end

  end
end
