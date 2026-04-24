import * as d3 from "d3";

export default {
  mounted() {
    this.handleEvent("graph:update", ({ nodes, links }) => this.render(nodes, links));
    this.handleEvent("graph:flash", ({ from, to }) => this.flash(from, to));
  },
  render(nodes, links) {
    const el = this.el;
    el.innerHTML = "";
    const width = el.clientWidth || 800;
    const height = 400;

    const svg = d3.select(el).append("svg")
      .attr("viewBox", [0, 0, width, height]);

    const sim = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(120))
      .force("charge", d3.forceManyBody().strength(-200))
      .force("center", d3.forceCenter(width / 2, height / 2));

    const link = svg.append("g")
      .attr("stroke", "#aaa")
      .selectAll("line")
      .data(links)
      .join("line")
      .attr("data-from", d => d.source.id || d.source)
      .attr("data-to", d => d.target.id || d.target);

    const node = svg.append("g")
      .selectAll("circle")
      .data(nodes)
      .join("circle")
      .attr("r", 16)
      .attr("fill", "#4f46e5");

    const label = svg.append("g")
      .selectAll("text")
      .data(nodes)
      .join("text")
      .text(d => d.id)
      .attr("font-size", 11)
      .attr("text-anchor", "middle")
      .attr("dy", 4)
      .attr("fill", "white");

    sim.on("tick", () => {
      link.attr("x1", d => d.source.x).attr("y1", d => d.source.y)
          .attr("x2", d => d.target.x).attr("y2", d => d.target.y);
      node.attr("cx", d => d.x).attr("cy", d => d.y);
      label.attr("x", d => d.x).attr("y", d => d.y);
    });

    this._svg = svg;
  },
  flash(from, to) {
    if (!this._svg) return;
    this._svg.selectAll("line")
      .filter(function() {
        return (this.dataset.from === from && this.dataset.to === to) ||
               (this.dataset.from === to && this.dataset.to === from);
      })
      .attr("stroke", "#f59e0b").attr("stroke-width", 4)
      .transition().duration(800)
      .attr("stroke", "#aaa").attr("stroke-width", 1);
  }
};
